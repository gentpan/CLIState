import CLIStateDomain
import Foundation

/// Normalizes and classifies raw PATH entries (§107, §108). Reads directory
/// metadata only; `executableCount` is filled in by `BinaryScanner.annotate`.
public struct PATHResolver: Sendable {
    private let fileSystem: FileSystem
    private let protected: ProtectedLocations

    public init(fileSystem: FileSystem) {
        self.fileSystem = fileSystem
        self.protected = ProtectedLocations(home: fileSystem.homeDirectory)
    }

    /// - Parameters:
    ///   - path: Raw entries in order, as in `ShellEnvironment.path`.
    ///   - variables: Session environment, used for `HOMEBREW_PREFIX`, `CARGO_HOME`, ….
    public func resolve(path: [String], variables: [String: String] = [:]) -> [PATHEntry] {
        resolveWithListings(path: path, variables: variables).entries
    }

    /// Also returns the directory listings used for the readability check, keyed by
    /// priority, so `BinaryScanner` scans exactly what was checked without listing twice.
    func resolveWithListings(path: [String], variables: [String: String]) -> (entries: [PATHEntry], listings: [Int: DirectoryListing]) {
        let classifier = PATHSourceClassifier(home: fileSystem.homeDirectory, variables: variables)
        var firstByNormalized: [String: Int] = [:]
        var firstByRealPath: [String: Int] = [:]
        var listings: [Int: DirectoryListing] = [:]
        var entries: [PATHEntry] = []
        entries.reserveCapacity(path.count)

        for (index, raw) in path.enumerated() {
            let priority = index + 1
            let normalized = normalize(raw)
            var entry = PATHEntry(priority: priority, rawValue: raw, normalizedPath: normalized, status: .ok, source: .unknown)

            if normalized.isEmpty {
                entry.status = .empty
                entries.append(entry)
                continue
            }
            guard normalized.hasPrefix("/") else {
                entry.status = .relative
                entries.append(entry)
                continue
            }
            entry.source = classifier.classify(normalized)

            if let first = firstByNormalized[normalized] {
                entry.status = .duplicate
                entry.duplicateOf = first
                entries.append(entry)
                continue
            }
            firstByNormalized[normalized] = priority

            let (status, realPath) = inspectDirectory(normalized)
            entry.status = status
            if status == .ok, let realPath {
                if let first = firstByRealPath[realPath] {
                    entry.status = .duplicate
                    entry.duplicateOf = first
                } else {
                    firstByRealPath[realPath] = priority
                    if let names = try? fileSystem.contentsOfDirectory(atPath: realPath) {
                        listings[priority] = DirectoryListing(realPath: realPath, names: names)
                        entry.isWritable = fileSystem.isWritable(atPath: realPath)
                    } else {
                        entry.status = .unreadable
                    }
                }
            }
            entries.append(entry)
        }
        return (entries, listings)
    }

    /// Expands `~` / `~/…` and strips trailing slashes (keeping `/`). Everything
    /// else is left untouched so relative entries stay recognizable.
    public func normalize(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var value = raw
        let home = fileSystem.homeDirectory
        if value == "~" {
            value = home
        } else if value.hasPrefix("~/") {
            value = (home.hasSuffix("/") ? String(home.dropLast()) : home) + value.dropFirst()
        }
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    /// Status for an absolute, not-yet-seen path plus its realpath when it is a directory.
    private func inspectDirectory(_ path: String) -> (PATHEntryStatus, String?) {
        // Checked before any filesystem call: even `lstat` inside these folders can prompt.
        if protected.contains(path) { return (.protectedLocation, nil) }
        if fileSystem.attributes(atPath: path)?.kind == .symlink,
           let destination = try? fileSystem.destinationOfSymbolicLink(atPath: path) {
            let parent = (path as NSString).deletingLastPathComponent
            if protected.contains(BinaryScanner.absolute(destination, relativeTo: parent)) { return (.protectedLocation, nil) }
        }
        guard let realPath = fileSystem.resolvingSymlinks(atPath: path) else { return (.missing, nil) }
        if realPath != path, protected.contains(realPath) { return (.protectedLocation, nil) }
        guard fileSystem.attributes(atPath: realPath)?.kind == .directory else { return (.notDirectory, nil) }
        return (.ok, realPath)
    }
}

/// Maps a normalized absolute directory to the tool family that usually owns it.
/// This is display metadata and a weak hint only (§37); attribution never relies on it.
struct PATHSourceClassifier {
    private let home: String
    private let variables: [String: String]

    init(home: String, variables: [String: String]) {
        self.home = home.hasSuffix("/") && home != "/" ? String(home.dropLast()) : home
        self.variables = variables
    }

    func classify(_ path: String) -> PATHSource {
        if isSystem(path) { return .system }
        if path.contains(".app/Contents/") || path.hasSuffix(".app/Contents") { return .application }
        if matches(path, homebrewRoots) { return .homebrew }
        if matches(path, versionManagerRoots) || path.contains("/fnm_multishells/") { return .versionManager }
        if matchesExactly(path, cargoBins) { return .cargo }
        if matchesExactly(path, goBins) { return .go }
        if matchesExactly(path, bunBins) { return .bun }
        if let prefix = variable("NPM_CONFIG_PREFIX"), path == Self.join(prefix, "bin") { return .npm }
        if matchesExactly(path, [home + "/.local/bin", "/usr/local/bin", home + "/bin"]) { return .userLocal }
        return .unknown
    }

    private func isSystem(_ path: String) -> Bool {
        let exact = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/libexec"]
        if exact.contains(path) { return true }
        return matches(path, [
            "/System",
            "/Library/Apple",
            "/var/run/com.apple.security.cryptexd",
            "/private/var/run/com.apple.security.cryptexd",
        ])
    }

    private var homebrewRoots: [String] {
        var roots = ["/opt/homebrew", "/usr/local/Homebrew"]
        if let prefix = variable("HOMEBREW_PREFIX"), prefix != "/" { roots.append(prefix) }
        return roots
    }

    private var versionManagerRoots: [String] {
        var roots = [
            home + "/.nvm",
            home + "/.fnm",
            home + "/Library/Application Support/fnm",
            home + "/.local/share/fnm",
            home + "/.volta",
            home + "/.asdf",
            home + "/.local/share/mise",
            home + "/.pyenv",
            home + "/.rbenv",
        ]
        for key in ["NVM_DIR", "FNM_DIR", "VOLTA_HOME", "ASDF_DATA_DIR", "MISE_DATA_DIR", "PYENV_ROOT", "RBENV_ROOT"] {
            if let value = variable(key), value != "/" { roots.append(value) }
        }
        if let xdg = variable("XDG_DATA_HOME") { roots.append(Self.join(xdg, "mise")) }
        return roots
    }

    private var cargoBins: [String] {
        [home + "/.cargo/bin"] + (variable("CARGO_HOME").map { [Self.join($0, "bin")] } ?? [])
    }

    private var goBins: [String] {
        var bins = [home + "/go/bin"]
        if let gobin = variable("GOBIN") { bins.append(Self.strip(gobin)) }
        if let gopath = variable("GOPATH") {
            bins += gopath.split(separator: ":").map { Self.join(String($0), "bin") }
        }
        return bins
    }

    private var bunBins: [String] {
        [home + "/.bun/bin"] + (variable("BUN_INSTALL").map { [Self.join($0, "bin")] } ?? [])
    }

    private func variable(_ key: String) -> String? {
        guard let value = variables[key], value.hasPrefix("/") else { return nil }
        return Self.strip(value)
    }

    private func matches(_ path: String, _ roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func matchesExactly(_ path: String, _ candidates: [String]) -> Bool {
        candidates.contains(path)
    }

    private static func strip(_ value: String) -> String {
        var value = value
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func join(_ base: String, _ component: String) -> String {
        let base = strip(base)
        return base == "/" ? "/" + component : base + "/" + component
    }
}
