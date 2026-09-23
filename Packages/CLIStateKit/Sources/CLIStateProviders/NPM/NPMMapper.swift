import CLIStateDomain
import Foundation

enum NPMMapper {
    static func instanceID(root: String) -> ProviderInstanceID {
        ProviderInstanceID("npm@\(root)")
    }

    static func layout(root: String, prefix: String?) -> ProviderLayout {
        var layout = ProviderLayout(roots: [.npmGlobalRoot: root])
        if let prefix { layout[.npmGlobalBin] = prefix + "/bin" }
        return layout
    }

    static func tool(
        name: String,
        dependency: NPMListDTO.Dependency,
        packageJSON: NPMPackageJSONDTO?,
        root: String,
        instanceID: ProviderInstanceID,
        outdated: [String: NPMOutdatedDTO.Entry]?
    ) -> ProviderTool {
        let version = dependency.version
        let entry = outdated?[name]
        let isOutdated: Bool? = outdated.map { _ in
            guard let entry, let latest = entry.latest else { return false }
            return latest != (entry.current ?? version)
        }
        return ProviderTool(
            providerID: .npm,
            instanceID: instanceID,
            packageName: name,
            kind: .globalPackage,
            summary: packageJSON?.description,
            homepage: packageJSON?.homepage,
            installedVersions: version.map { [$0] } ?? [],
            activeVersion: version,
            latestVersion: entry?.latest,
            isOutdated: isOutdated,
            installPrefix: "\(root)/\(name)",
            executableNames: executableNames(packageName: packageJSON?.name ?? name, bin: packageJSON?.bin),
            // Everything `npm list -g --depth=0` shows was installed explicitly.
            isDirect: true
        )
    }

    /// npm's own rule: a string `bin` is exposed under the unscoped package name.
    static func executableNames(packageName: String, bin: NPMPackageJSONDTO.Bin?) -> [String] {
        switch bin {
        case nil:
            return []
        case let .single(path):
            guard !path.isEmpty else { return [] }
            let unscoped = packageName.split(separator: "/").last.map(String.init) ?? packageName
            return [unscoped]
        case let .named(entries):
            return entries.keys.filter { !$0.isEmpty }.sorted()
        }
    }

    /// Classifies an npm by where its realpath lives (§157, F8).
    /// - Parameter homebrewPrefix: `<prefix>` of a resolved `brew`, if any.
    static func environmentContext(npmRealPath path: String, homebrewPrefix: String?, fileSystem: any FileSystem) -> EnvironmentContext {
        let components = path.split(separator: "/").map(String.init)

        func component(after marker: [String]) -> (index: Int, value: String)? {
            guard marker.count < components.count else { return nil }
            for start in 0...(components.count - marker.count - 1) where Array(components[start..<(start + marker.count)]) == marker {
                return (start, components[start + marker.count])
            }
            return nil
        }
        func versionString(_ raw: String) -> String {
            raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        }
        func earlierComponentContains(_ needle: String, before index: Int) -> Bool {
            components[..<index].contains { $0.lowercased().contains(needle) }
        }

        if let match = component(after: ["versions", "node"]), earlierComponentContains("nvm", before: match.index) {
            return .nvm(version: versionString(match.value))
        }
        if let match = component(after: ["node-versions"]), earlierComponentContains("fnm", before: match.index) {
            return .fnm(version: versionString(match.value))
        }
        if components.contains(where: { $0.lowercased() == ".volta" || $0 == "Volta" }) {
            return .volta
        }
        if let match = component(after: ["installs", "node"]), earlierComponentContains("mise", before: match.index) {
            return .mise(version: versionString(match.value))
        }
        if let match = component(after: ["installs", "nodejs"]), earlierComponentContains("asdf", before: match.index) {
            return .asdf(version: versionString(match.value))
        }
        if let prefix = homebrewPrefix, !prefix.isEmpty, prefix != "/" {
            if path.hasPrefix(prefix + "/Cellar/") { return .homebrew }
            // Homebrew's node keeps npm in `<prefix>/lib/node_modules` (F8), which a
            // nodejs.org installer under /usr/local would share, so require the keg.
            if path.hasPrefix(prefix + "/lib/node_modules/"), homebrewNodeInstalled(prefix: prefix, fileSystem: fileSystem) {
                return .homebrew
            }
        }
        return .standalone
    }

    private static func homebrewNodeInstalled(prefix: String, fileSystem: any FileSystem) -> Bool {
        guard let entries = try? fileSystem.contentsOfDirectory(atPath: prefix + "/Cellar") else { return false }
        return entries.contains { $0 == "node" || $0.hasPrefix("node@") }
    }
}
