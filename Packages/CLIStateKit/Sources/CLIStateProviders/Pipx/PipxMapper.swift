import CLIStateDomain
import Foundation

enum PipxMapper {
    static func layout(venvs: String?, binDir: String?) -> ProviderLayout {
        var layout = ProviderLayout()
        layout[.pipxVenvs] = venvs
        layout[.pipxBinDir] = binDir
        return layout
    }

    static func tool(name: String, venv: PipxListDTO.Venv, venvsRoot: String?) -> ProviderTool {
        let package = venv.mainPackage
        var names = package?.apps ?? []
        var paths = package?.appPaths ?? []
        // `pipx install --include-deps` also exposes the dependencies' apps.
        if let package, package.includeDependencies {
            names += package.appsOfDependencies
            paths += package.appPathsOfDependencies
        }
        paths = paths.filter { $0.hasPrefix("/") }
        let version = package?.packageVersion.flatMap { $0.isEmpty ? nil : $0 }
        return ProviderTool(
            providerID: .pipx,
            packageName: name,
            kind: .tool,
            installedVersions: version.map { [$0] } ?? [],
            activeVersion: version,
            isPinned: package?.pinned ?? false,
            installPrefix: venvsRoot.map { "\($0)/\(name)" } ?? venvDirectory(fromAppPath: paths.first),
            executableNames: names.filter { !$0.isEmpty }.uniquedPreservingOrder(),
            executablePaths: paths.uniquedPreservingOrder(),
            // Every venv pipx lists was installed explicitly.
            isDirect: true
        )
    }

    /// `<venvs>/<name>/bin/<app>` → `<venvs>/<name>`, for when
    /// `pipx environment` is unavailable.
    static func venvDirectory(fromAppPath path: String?) -> String? {
        guard let path else { return nil }
        let bin = (path as NSString).deletingLastPathComponent
        guard (bin as NSString).lastPathComponent == "bin" else { return nil }
        let venv = (bin as NSString).deletingLastPathComponent
        return venv.count > 1 ? venv : nil
    }
}
