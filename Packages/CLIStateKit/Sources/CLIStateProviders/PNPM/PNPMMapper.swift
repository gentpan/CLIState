import CLIStateDomain
import Foundation

enum PNPMMapper {
    /// Versions pnpm reports for packages that did not come from a registry,
    /// e.g. `pnpm link -g` → `link:../../src/tool`.
    static let localVersionPrefixes = ["link:", "file:"]

    static func layout(root: String, globalBin: String?) -> ProviderLayout {
        var layout = ProviderLayout(roots: [.pnpmGlobalRoot: root])
        layout[.pnpmGlobalBin] = globalBin
        return layout
    }

    static func isLocal(version: String?) -> Bool {
        guard let version else { return false }
        return localVersionPrefixes.contains { version.hasPrefix($0) }
    }

    static func tool(
        name: String,
        dependency: PNPMListDTO.Dependency,
        packageJSON: NPMPackageJSONDTO?,
        root: String,
        globalBin: String?,
        outdated: [String: PNPMOutdatedDTO.Entry]?
    ) -> ProviderTool {
        let isLocal = isLocal(version: dependency.version)
        let version = isLocal ? nil : dependency.version
        let entry = outdated?[name]
        let isOutdated: Bool? = isLocal ? nil : outdated.map { _ in
            guard let entry, let latest = entry.latest else { return false }
            return latest != (entry.current ?? version)
        }
        // pnpm's bin rules match npm's; the files in the global bin are shims.
        let names = NPMMapper.executableNames(packageName: packageJSON?.name ?? name, bin: packageJSON?.bin)
        return ProviderTool(
            providerID: .pnpm,
            packageName: name,
            kind: .globalPackage,
            summary: packageJSON?.description,
            homepage: packageJSON?.homepage,
            installedVersions: version.map { [$0] } ?? [],
            activeVersion: version,
            latestVersion: isLocal ? nil : entry?.latest,
            isOutdated: isOutdated,
            // Linked packages point at a local checkout; `pnpm add -g <name>@latest`
            // would replace it with the registry release.
            isPinned: isLocal,
            installPrefix: "\(root)/\(name)",
            executableNames: names,
            executablePaths: globalBin.map { bin in names.map { "\(bin)/\($0)" } } ?? [],
            isDirect: true
        )
    }
}
