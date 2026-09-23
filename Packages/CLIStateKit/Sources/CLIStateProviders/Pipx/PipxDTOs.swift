import Foundation

// Raw pipx JSON shapes. Tolerant: optionals everywhere, unknown keys ignored.

/// `pipx list --json`, keyed by venv name (the name `pipx upgrade` takes).
struct PipxListDTO: Decodable {
    struct Venv: Decodable {
        var mainPackage: Package?

        enum CodingKeys: String, CodingKey { case metadata }
        enum MetadataKeys: String, CodingKey { case mainPackage = "main_package" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let metadata = try? container.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata)
            mainPackage = metadata?.lenient(Package.self, forKey: .mainPackage)
        }
    }

    struct Package: Decodable {
        var package: String?
        var packageVersion: String?
        var apps: [String]
        var appPaths: [String]
        var includeDependencies: Bool
        var appsOfDependencies: [String]
        var appPathsOfDependencies: [String]
        var pinned: Bool?

        enum CodingKeys: String, CodingKey {
            case package
            case packageVersion = "package_version"
            case apps
            case appPaths = "app_paths"
            case includeDependencies = "include_dependencies"
            case appsOfDependencies = "apps_of_dependencies"
            case appPathsOfDependencies = "app_paths_of_dependencies"
            case pinned
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            package = container.lenient(String.self, forKey: .package)
            packageVersion = container.lenient(String.self, forKey: .packageVersion)
            apps = container.lenient(LossyArray<String>.self, forKey: .apps)?.elements ?? []
            appPaths = container.lenient(LossyArray<PipxPathDTO>.self, forKey: .appPaths)?.elements.compactMap(\.path) ?? []
            includeDependencies = container.lenient(Bool.self, forKey: .includeDependencies) ?? false
            appsOfDependencies = container.lenient(LossyArray<String>.self, forKey: .appsOfDependencies)?.elements ?? []
            let byDependency = container.lenient(LossyDictionary<LossyArray<PipxPathDTO>>.self, forKey: .appPathsOfDependencies)?.values ?? [:]
            appPathsOfDependencies = byDependency.keys.sorted().flatMap { byDependency[$0]?.elements.compactMap(\.path) ?? [] }
            pinned = container.lenient(Bool.self, forKey: .pinned)
        }
    }

    var venvs: [String: Venv]

    enum CodingKeys: String, CodingKey { case venvs }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        venvs = container.lenient(LossyDictionary<Venv>.self, forKey: .venvs)?.values ?? [:]
    }
}

/// pipx serializes `pathlib.Path` as `{"__type__": "Path", "__Path__": "/abs"}`.
/// A plain string is accepted too.
struct PipxPathDTO: Decodable {
    var path: String?

    enum CodingKeys: String, CodingKey { case path = "__Path__" }

    init(from decoder: Decoder) throws {
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            path = string
            return
        }
        path = try decoder.container(keyedBy: CodingKeys.self).lenient(String.self, forKey: .path)
    }
}
