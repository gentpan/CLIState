import Foundation

// Raw pnpm JSON shapes. Tolerant: optionals everywhere, unknown keys ignored.

/// `pnpm list -g --depth=0 --json`: an array with one entry per importer
/// (for `-g`, the global directory). A bare object is accepted too.
struct PNPMListDTO: Decodable {
    struct Importer: Decodable {
        var path: String?
        var dependencies: [String: Dependency]

        enum CodingKeys: String, CodingKey { case path, dependencies }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = container.lenient(String.self, forKey: .path)
            dependencies = container.lenient(LossyDictionary<Dependency>.self, forKey: .dependencies)?.values ?? [:]
        }
    }

    struct Dependency: Decodable {
        var version: String?
        /// Real package directory inside pnpm's virtual store.
        var path: String?

        enum CodingKeys: String, CodingKey { case version, path }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = container.lenient(String.self, forKey: .version)
            path = container.lenient(String.self, forKey: .path)
        }
    }

    var importers: [Importer]

    init(from decoder: Decoder) throws {
        if (try? decoder.unkeyedContainer()) != nil {
            importers = try LossyArray<Importer>(from: decoder).elements
        } else {
            importers = [try Importer(from: decoder)]
        }
    }

    /// All importers' dependencies; the first importer listing a name wins.
    var dependencies: [String: Dependency] {
        importers.reduce(into: [:]) { result, importer in
            result.merge(importer.dependencies) { first, _ in first }
        }
    }
}

/// `pnpm outdated -g --format json`: one object per outdated package.
struct PNPMOutdatedDTO: Decodable {
    struct Entry: Decodable {
        var current: String?
        var wanted: String?
        var latest: String?

        enum CodingKeys: String, CodingKey { case current, wanted, latest }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            current = container.lenient(String.self, forKey: .current)
            wanted = container.lenient(String.self, forKey: .wanted)
            latest = container.lenient(String.self, forKey: .latest)
        }
    }

    var packages: [String: Entry]

    init(from decoder: Decoder) throws {
        packages = try LossyDictionary<Entry>(from: decoder).values
    }
}
