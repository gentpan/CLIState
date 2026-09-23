import CLIStateDomain
import Foundation

/// Decides what an installation occupies on disk and measures it. Read-only: it
/// lists directories and reads attributes (`lstat`), never file contents, so it
/// doesn't change any file's access time either.
public struct DiskUsageMeasurer: Sendable {
    public enum Target: Hashable, Sendable {
        /// A directory walked without following the symlinks inside it. A symlinked
        /// root (pnpm's global packages) is resolved once; a file root counts itself.
        case tree(String)
        /// One file, e.g. a Cargo binary or a standalone executable; a symlink counts its target.
        case file(String)
    }

    public struct Measurement: Hashable, Sendable {
        public var bytes: Int64
        /// The walk hit its entry limit or an unreadable directory, so `bytes` is a lower bound.
        public var isPartial: Bool
        public var entries: Int
    }

    /// Directory entries visited per installation before the size becomes a lower bound.
    public static let defaultEntryLimit = 100_000

    /// Home-relative folders never walked or stat'ed: TCC prompts (plan F12) and other apps' data.
    static let excludedHomeFolders = LeftoverScanner.personalFolders + ["Library/Containers", "Library/Group Containers"]

    private let fileSystem: any FileSystem
    private let registry: ToolRegistry
    private let context: AttributionContext
    private let entryLimit: Int
    private let excludedRoots: [String]

    public init(fileSystem: any FileSystem, registry: ToolRegistry = .standard, context: AttributionContext, entryLimit: Int = defaultEntryLimit) {
        self.fileSystem = fileSystem
        self.registry = registry
        self.context = context
        self.entryLimit = max(1, entryLimit)
        // Removable and network volumes are TCC-protected too.
        excludedRoots = (Self.excludedHomeFolders.map { PathUtil.join(context.homeDirectory, $0) } + ["/Volumes"]).map { $0.lowercased() }
    }

    // MARK: Targets

    /// Empty for system-managed installations and when nothing safe is left to measure.
    public func targets(for installation: ToolInstallation, registryID: String?) -> [Target] {
        guard !installation.isSystemManaged, installation.ownership.provider != .system else { return [] }
        let provider = installation.ownership.provider
        let prefix = installation.installPrefix.map(PathUtil.trimmed)
        let executables = executableTargets(installation)

        let targets: [Target]
        switch provider {
        case .homebrew:
            if let prefix, homebrewPackageDirectory(prefix, below: "Caskroom") {
                targets = [.tree(prefix)] + caskAppBundles(versionDirectory: prefix, installation: installation).map(Target.tree)
            } else if let prefix, homebrewPackageDirectory(prefix, below: "Cellar") {
                targets = [.tree(prefix)]
            } else {
                // Homebrew's own `brew`, scripts run by a keg's interpreter, prefix-less inventory entries.
                targets = executables
            }
        case .npm, .pnpm, .bun, .uv, .pipx, .appBundle:
            targets = prefix.map { [.tree($0)] } ?? executables
        case _ where ProviderID.versionManagers.contains(provider):
            // A version directory (nvm, pyenv, rustup toolchain…); rustup's proxies have none.
            targets = prefix.map { [.tree($0)] } ?? executables
        case .native:
            if let prefix, isVersionedNativeDirectory(prefix, registryID: registryID) {
                targets = [.tree(prefix)]
            } else {
                // `~/.bun/bin`-style layouts share their parent with caches and data.
                targets = executables
            }
        default:
            // Cargo (`installPrefix` is the shared bin directory), standalone and unknown executables.
            targets = executables
        }
        return targets.filter(isAllowed).uniqued()
    }

    private func executableTargets(_ installation: ToolInstallation) -> [Target] {
        installation.executables.compactMap { executable in
            guard let resolved = executable.resolvedPath ?? fileSystem.resolvingSymlinks(atPath: executable.path) else { return nil }
            return .file(resolved)
        }
    }

    /// `<prefix>/Cellar/<name>/<version>` or `<prefix>/Caskroom/<token>/<version>`.
    private func homebrewPackageDirectory(_ path: String, below directory: String) -> Bool {
        context.homebrewPrefixes.contains { PathUtil.components(of: path, below: "\($0)/\(directory)")?.count == 2 }
    }

    /// Apps a cask installed: Homebrew leaves `<version>/<App>.app` links to the moved
    /// bundle, and `binary` artifacts resolve into the bundle.
    private func caskAppBundles(versionDirectory: String, installation: ToolInstallation) -> [String] {
        var bundles: [String] = []
        for name in ((try? fileSystem.contentsOfDirectory(atPath: versionDirectory)) ?? []).sorted() where name.hasSuffix(".app") {
            let link = PathUtil.join(versionDirectory, name)
            guard fileSystem.attributes(atPath: link)?.kind == .symlink,
                  let resolved = fileSystem.resolvingSymlinks(atPath: link), resolved.hasSuffix(".app")
            else { continue }
            bundles.append(resolved)
        }
        for executable in installation.executables {
            guard let resolved = executable.resolvedPath, let range = resolved.range(of: ".app/Contents/") else { continue }
            bundles.append(String(resolved[..<range.lowerBound]) + ".app")
        }
        return bundles.uniqued()
    }

    /// Claude Code's `~/.local/share/claude/versions/<version>`: one entry per version.
    private func isVersionedNativeDirectory(_ prefix: String, registryID: String?) -> Bool {
        guard let definition = registryID.flatMap({ registry.definition(ToolID($0)) }) else { return false }
        return definition.nativeLayouts.contains { layout in
            guard case let .versionedRoot(template) = layout.kind else { return false }
            return PathUtil.directory(of: prefix) == PathUtil.trimmed(context.expand(template))
        }
    }

    // MARK: Safety

    private func isAllowed(_ target: Target) -> Bool {
        switch target {
        case let .tree(path): isAllowedTree(path)
        case let .file(path): isAllowedPath(path)
        }
    }

    /// Absolute, not excluded, and not a shared container that holds far more than one
    /// installation: never the home directory or an ancestor of it or of an excluded folder.
    func isAllowedTree(_ path: String) -> Bool {
        guard isAllowedPath(path) else { return false }
        let lowered = path.lowercased()
        guard !PathUtil.isInside(context.homeDirectory, path),
              !excludedRoots.contains(where: { PathUtil.isInside($0, lowered) })
        else { return false }
        let depth = path.split(separator: "/").count
        return depth >= 3 || (depth == 2 && path.hasSuffix(".app"))
    }

    /// Case-insensitive because the default APFS volume is.
    func isAllowedPath(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard path.hasPrefix("/"), !components.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        let lowered = path.lowercased()
        return !excludedRoots.contains { PathUtil.isInside(lowered, $0) }
    }

    // MARK: Measuring

    /// Sums regular-file sizes, counting each hard-linked inode once. `nil` when no target exists.
    public func measure(_ targets: [Target]) -> Measurement? {
        let trees = targets.compactMap { target -> String? in
            if case let .tree(path) = target { return fileSystem.resolvingSymlinks(atPath: path) ?? path }
            return nil
        }
        var walk = Walk(limit: entryLimit)
        var found = false
        for target in targets.uniqued() {
            switch target {
            case let .tree(root):
                guard let resolved = fileSystem.resolvingSymlinks(atPath: root), isAllowedTree(resolved) else { continue }
                // Another target already covers it, e.g. an app bundle kept inside its Caskroom directory.
                if trees.contains(where: { $0 != resolved && PathUtil.isInside(resolved, $0) }) { continue }
                guard let attributes = fileSystem.attributes(atPath: resolved) else { continue }
                found = true
                switch attributes.kind {
                case .file: walk.add(attributes)
                case .directory: walkTree(resolved, into: &walk)
                case .symlink, .other: break
                }
            case let .file(path):
                guard let resolved = fileSystem.resolvingSymlinks(atPath: path), isAllowedPath(resolved),
                      !trees.contains(where: { PathUtil.isInside(resolved, $0) }),
                      let attributes = fileSystem.attributes(atPath: resolved), attributes.kind == .file
                else { continue }
                found = true
                walk.add(attributes)
            }
            if walk.isLimited { break }
        }
        guard found else { return nil }
        return Measurement(bytes: walk.bytes, isPartial: walk.isPartial, entries: walk.entries)
    }

    private func walkTree(_ root: String, into walk: inout Walk) {
        var pending = [root]
        while let directory = pending.popLast() {
            guard let names = try? fileSystem.contentsOfDirectory(atPath: directory) else {
                walk.isPartial = true
                continue
            }
            for name in names {
                guard walk.visit() else { return }
                let child = PathUtil.join(directory, name)
                guard let entry = fileSystem.attributes(atPath: child) else { continue }
                switch entry.kind {
                case .directory: pending.append(child)
                case .file: walk.add(entry)
                case .symlink, .other: break
                }
            }
        }
    }

    private struct Walk {
        let limit: Int
        var bytes: Int64 = 0
        var entries = 0
        var isPartial = false
        var isLimited = false
        var linkedInodes = Set<UInt64>()

        init(limit: Int) {
            self.limit = limit
        }

        mutating func visit() -> Bool {
            entries += 1
            guard entries <= limit else {
                isPartial = true
                isLimited = true
                return false
            }
            return true
        }

        mutating func add(_ attributes: FileAttributes) {
            if let links = attributes.linkCount, links > 1, let inode = attributes.inode {
                guard linkedInodes.insert(inode).inserted else { return }
            }
            bytes += max(0, attributes.size)
        }
    }
}
