import CLIStateDomain
import Foundation

/// A leftover location declared in the registry, relative to the home directory.
public struct LeftoverLocation: Hashable, Sendable {
    /// Always starts with `~/`; no templates or globs.
    public var path: String
    public var kind: LeftoverKind

    public init(_ path: String, _ kind: LeftoverKind) {
        precondition(path.hasPrefix("~/") && !path.contains("*"), "Leftover locations are exact paths in the home directory")
        self.path = path
        self.kind = kind
    }
}

/// Finds files a tool left in the home directory: registry-declared locations
/// first, then standard cache/log/state/config directories whose name exactly
/// equals the tool or package name. Read-only.
///
/// Every candidate must pass all safety rules, on its own path and on its
/// resolved target: inside the home directory, not a top-level or shared
/// container, not a personal or iCloud folder, not shell configuration, not the
/// installation itself, not claimed by another installed tool, and owned by
/// the current user.
public struct LeftoverScanner: LeftoverScanning {
    public enum Rejection: Hashable, Sendable {
        case notAbsolute
        case outsideHome
        case homeDirectory
        /// `~/Library`, `~/.config`, `~/Library/Caches`, keychains, SSH keys…
        case protectedLocation
        /// Desktop, Documents, Downloads, iCloud Drive and cloud storage.
        case personalFolder
        case shellConfiguration
        /// The tool's own install prefix, executables or installer receipt.
        case installation
        /// Another installed tool's prefix, executables, registry leftovers or name.
        case otherTool(ToolID)
        /// Contains or equals a PATH directory.
        case pathEntry
        /// Absent, or present only under a different letter case.
        case missing
        /// A symlink along the path is broken or loops.
        case unresolvable
        case notOwnedByUser
    }

    /// Directory entries visited per item before the size becomes a lower bound.
    public static let defaultEntryLimit = 10_000

    /// Standard per-application directories searched by exact name.
    static let exactNameContainers: [(path: String, kind: LeftoverKind)] = [
        ("Library/Caches", .cache),
        ("Library/Logs", .logs),
        (".cache", .cache),
        (".local/state", .state),
        (".config", .config),
    ]

    /// Shared containers: never a leftover themselves, and neither are their ancestors.
    static let containers: Set<String> = [
        "Library", "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Preferences",
        "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit",
        ".config", ".cache", ".local", ".local/state", ".local/share", ".local/bin", ".local/lib",
    ]

    /// Trees nothing is ever taken from.
    static let sensitiveTrees = [
        "Library/Keychains", "Library/Containers", "Library/Group Containers", "Library/LaunchAgents",
        "Library/Mail", "Library/Messages", "Library/Cookies", ".ssh", ".gnupg", ".Trash",
    ]

    static let personalFolders = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public",
        "Library/Mobile Documents", "Library/CloudStorage",
    ]

    static let shellConfiguration = [
        ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout", ".zsh_history", ".zsh_sessions",
        ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".bash_history", ".bash_sessions",
        ".profile", ".inputrc", ".cshrc", ".tcshrc", ".oh-my-zsh", ".config/fish", ".config/zsh",
    ]

    private let fileSystem: any FileSystem
    private let registry: ToolRegistry
    private let entryLimit: Int

    public init(fileSystem: any FileSystem, registry: ToolRegistry = .standard, entryLimit: Int = defaultEntryLimit) {
        self.fileSystem = fileSystem
        self.registry = registry
        self.entryLimit = max(1, entryLimit)
    }

    // MARK: Scanning

    public func leftovers(for tool: ToolID, in snapshot: EnvironmentSnapshot) -> [LeftoverItem] {
        let rules = Rules(tool: tool, snapshot: snapshot, scanner: self)
        var seen = Set<String>()
        var items: [LeftoverItem] = []
        for candidate in candidates(for: tool, in: snapshot) where seen.insert(candidate.path).inserted {
            guard evaluate(candidate.path, origin: candidate.origin, rules: rules) == nil else { continue }
            let size = measure(candidate.path)
            items.append(LeftoverItem(path: candidate.path, kind: candidate.kind, origin: candidate.origin, sizeBytes: size.bytes, sizeIsLowerBound: size.isLowerBound))
        }
        return items
    }

    /// Why `path` can't be a leftover of `tool`, or `nil` when it can.
    public func rejection(for path: String, origin: LeftoverItem.Origin = .registry, tool: ToolID, in snapshot: EnvironmentSnapshot) -> Rejection? {
        evaluate(path, origin: origin, rules: Rules(tool: tool, snapshot: snapshot, scanner: self))
    }

    // MARK: Candidates

    struct Candidate: Hashable {
        var path: String
        var kind: LeftoverKind
        var origin: LeftoverItem.Origin
    }

    func candidates(for tool: ToolID, in snapshot: EnvironmentSnapshot) -> [Candidate] {
        let home = PathUtil.trimmed(fileSystem.homeDirectory)
        var result = (definition(for: tool, in: snapshot)?.leftoverPaths ?? []).map {
            Candidate(path: PathUtil.expandingTilde($0.path, home: home), kind: $0.kind, origin: .registry)
        }
        for name in exactNames(for: tool, in: snapshot) {
            for container in Self.exactNameContainers {
                result.append(Candidate(path: PathUtil.join(home, container.path, name), kind: container.kind, origin: .exactName))
            }
        }
        return result
    }

    func definition(for tool: ToolID, in snapshot: EnvironmentSnapshot) -> ToolDefinition? {
        if let registryID = snapshot.tool(tool)?.identity.registryID, let definition = registry.definition(ToolID(registryID)) {
            return definition
        }
        return registry.definition(tool)
    }

    /// Tool, registry and package names usable as one exact path component.
    func exactNames(for tool: ToolID, in snapshot: EnvironmentSnapshot) -> [String] {
        var names: [String] = []
        if let installed = snapshot.tool(tool) {
            names.append(installed.identity.name)
            names += [installed.identity.registryID].compactMap { $0 }
            names += installed.installations.compactMap(\.ownership.packageName)
        }
        if let definition = definition(for: tool, in: snapshot) {
            names.append(definition.id.rawValue)
            names += definition.packages.keys.sorted().flatMap { definition.packages[$0] ?? [] }
        }
        return names.filter(Self.isExactName).uniqued()
    }

    static func isExactName(_ name: String) -> Bool {
        name.count >= 2 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
            && !name.contains(where: { "*?[]{}~".contains($0) }) && name.trimmingCharacters(in: .whitespacesAndNewlines) == name
    }

    // MARK: Rules

    /// Paths computed once per scan.
    struct Rules {
        var tool: ToolID
        var home: String
        var resolvedHome: String
        /// This tool's install prefixes, executables and installer receipts, raw and resolved.
        var ownInstallation: [String]
        var otherClaims: [(tool: ToolID, path: String)]
        var otherNames: [String: ToolID]
        var pathEntries: [String]

        init(tool: ToolID, snapshot: EnvironmentSnapshot, scanner: LeftoverScanner) {
            let fileSystem = scanner.fileSystem
            let home = PathUtil.trimmed(fileSystem.homeDirectory)
            self.tool = tool
            self.home = home
            resolvedHome = fileSystem.resolvingSymlinks(atPath: home) ?? home

            func withResolved(_ paths: [String]) -> [String] {
                paths.flatMap { path in [path, fileSystem.resolvingSymlinks(atPath: path)].compactMap { $0 } }.map(PathUtil.trimmed).uniqued()
            }
            func installationPaths(_ tool: Tool) -> [String] {
                tool.installations.flatMap { installation in
                    [installation.installPrefix].compactMap { $0 } + installation.executables.flatMap { [$0.path, $0.resolvedPath].compactMap { $0 } }
                }
            }

            // Installer receipts such as `~/.config/uv/uv-receipt.json` identify the installation.
            func markers(_ tool: ToolID) -> [String] {
                (scanner.definition(for: tool, in: snapshot)?.nativeLayouts ?? []).compactMap(\.marker).map { PathUtil.expandingTilde($0, home: home) }
            }

            ownInstallation = withResolved((snapshot.tool(tool).map(installationPaths) ?? []) + markers(tool))
            var claims: [(tool: ToolID, path: String)] = []
            var names: [String: ToolID] = [:]
            for other in snapshot.tools where other.id != tool {
                let declared = (scanner.definition(for: other.id, in: snapshot)?.leftoverPaths ?? []).map { PathUtil.expandingTilde($0.path, home: home) }
                claims += withResolved(installationPaths(other) + declared + markers(other.id)).map { (other.id, $0) }
                for name in scanner.exactNames(for: other.id, in: snapshot) where names[name] == nil {
                    names[name] = other.id
                }
            }
            otherClaims = claims
            otherNames = names
            pathEntries = withResolved(snapshot.pathEntries.map(\.normalizedPath))
        }
    }

    private func evaluate(_ path: String, origin: LeftoverItem.Origin, rules: Rules) -> Rejection? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"), !components.contains(where: { $0 == "." || $0 == ".." }) else { return .notAbsolute }
        let path = PathUtil.trimmed(path)

        if let rejection = locationRejection(path, home: rules.home, rules: rules) { return rejection }
        if origin == .exactName, let owner = rules.otherNames[PathUtil.lastComponent(path)] { return .otherTool(owner) }

        guard let attributes = fileSystem.attributes(atPath: path) else { return .missing }
        // Case-insensitive volumes report `~/Library/Caches/Yarn` for `…/yarn`; only the exact name counts.
        guard let siblings = try? fileSystem.contentsOfDirectory(atPath: PathUtil.directory(of: path)),
              siblings.contains(PathUtil.lastComponent(path))
        else { return .missing }

        guard let resolved = fileSystem.resolvingSymlinks(atPath: path) else { return .unresolvable }
        if resolved != path, let rejection = locationRejection(resolved, home: rules.resolvedHome, rules: rules) { return rejection }

        guard isOwnedByCurrentUser(attributes) else { return .notOwnedByUser }
        if resolved != path {
            guard let target = fileSystem.attributes(atPath: resolved), isOwnedByCurrentUser(target) else { return .notOwnedByUser }
        }
        return nil
    }

    private func locationRejection(_ path: String, home: String, rules: Rules) -> Rejection? {
        if path == home { return .homeDirectory }
        guard let components = PathUtil.components(of: path, below: home), !components.isEmpty else { return .outsideHome }
        let relative = components.joined(separator: "/")

        func within(_ roots: [String]) -> Bool {
            roots.contains { relative == $0 || relative.hasPrefix($0 + "/") }
        }
        if within(Self.personalFolders) { return .personalFolder }
        if within(Self.shellConfiguration) { return .shellConfiguration }
        if within(Self.sensitiveTrees) { return .protectedLocation }
        if components.count == 1, !relative.hasPrefix(".") { return .protectedLocation }
        let protected = Self.containers.union(Self.sensitiveTrees).union(Self.personalFolders)
        if protected.contains(where: { $0 == relative || $0.hasPrefix(relative + "/") }) { return .protectedLocation }

        func overlaps(_ other: String) -> Bool {
            PathUtil.isInside(path, other) || PathUtil.isInside(other, path)
        }
        if rules.ownInstallation.contains(where: overlaps) { return .installation }
        if let claim = rules.otherClaims.first(where: { overlaps($0.path) }) { return .otherTool(claim.tool) }
        if rules.pathEntries.contains(where: { PathUtil.isInside($0, path) }) { return .pathEntry }
        return nil
    }

    /// Unknown ownership fails closed.
    private func isOwnedByCurrentUser(_ attributes: FileAttributes) -> Bool {
        guard let owner = attributes.ownerID, let current = fileSystem.currentUserID else { return false }
        return owner == current
    }

    // MARK: Size

    /// Sums regular files without following symlinks; stops after `entryLimit` entries.
    func measure(_ path: String) -> (bytes: Int64, isLowerBound: Bool) {
        guard let attributes = fileSystem.attributes(atPath: path) else { return (0, true) }
        guard attributes.kind == .directory else { return (attributes.size, false) }
        var total: Int64 = 0
        var visited = 0
        var incomplete = false
        var pending = [path]
        while let directory = pending.popLast() {
            guard let names = try? fileSystem.contentsOfDirectory(atPath: directory) else {
                incomplete = true
                continue
            }
            for name in names {
                visited += 1
                if visited > entryLimit { return (total, true) }
                let child = PathUtil.join(directory, name)
                guard let entry = fileSystem.attributes(atPath: child) else { continue }
                switch entry.kind {
                case .directory: pending.append(child)
                case .file: total += entry.size
                case .symlink, .other: break
                }
            }
        }
        return (total, incomplete)
    }
}
