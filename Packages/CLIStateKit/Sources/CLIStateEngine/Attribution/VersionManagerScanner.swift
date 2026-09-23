import CLIStateDomain
import Foundation

/// Finds runtimes installed by version managers that are not on PATH (e.g. an
/// older nvm Node, a uv-managed CPython), so they show up as `notOnPath`
/// installations and cleanup suggestions. Reads directories only; never executes anything.
struct VersionManagerScanner: Sendable {
    let fileSystem: any FileSystem
    let registry: ToolRegistry
    let context: AttributionContext

    struct Found: Hashable, Sendable {
        var name: String
        var path: String
    }

    func scan() -> [Found] {
        var found: [Found] = []
        for definition in registry.definitions where !definition.versionManagerNames.isEmpty {
            var directories = context.versionManagerRoots.flatMap { versionDirectories(provider: $0.provider, root: $0.root, definition: definition) }
            if definition.id == "python" {
                directories += context.uvPythonDirectories.flatMap { root in
                    children(of: root).filter { UVPythonDirectory(name: PathUtil.lastComponent($0))?.isCPython == true }
                }
            }
            for directory in directories {
                for name in definition.executables {
                    let path = "\(directory)/bin/\(name)"
                    if fileSystem.isExecutableFile(atPath: path) {
                        found.append(Found(name: name, path: path))
                    }
                }
            }
        }
        return found.uniqued()
    }

    private func versionDirectories(provider: ProviderID, root: String, definition: ToolDefinition) -> [String] {
        let isNode = definition.id == "node"
        switch provider {
        case .nvm where isNode:
            return children(of: "\(root)/versions/node")
        case .fnm where isNode:
            return children(of: "\(root)/node-versions").map { "\($0)/installation" }
        case .pyenv where definition.id == "python", .rbenv where definition.id == "ruby":
            return children(of: "\(root)/versions")
        case .mise, .asdf:
            return definition.versionManagerNames.flatMap { children(of: "\(root)/installs/\($0)") }
        default:
            return []
        }
    }

    /// Real version directories only: alias symlinks (`lts`, `22 -> 22.1.0`) would duplicate installs.
    private func children(of directory: String) -> [String] {
        guard let names = try? fileSystem.contentsOfDirectory(atPath: directory) else { return [] }
        return names.sorted().compactMap { name in
            let path = "\(directory)/\(name)"
            guard !name.hasPrefix("."), fileSystem.attributes(atPath: path)?.kind == .directory else { return nil }
            return path
        }
    }
}
