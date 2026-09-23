import Foundation

// Raw npm JSON shapes. Tolerant: optionals everywhere, unknown keys ignored.

/// `npm list -g --depth=0 --json`
struct NPMListDTO: Decodable {
    struct Dependency: Decodable {
        var version: String?
        var missing: Bool?

        enum CodingKeys: String, CodingKey { case version, missing }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = container.lenient(String.self, forKey: .version)
            missing = container.lenient(Bool.self, forKey: .missing)
        }
    }

    var dependencies: [String: Dependency]

    enum CodingKeys: String, CodingKey { case dependencies }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dependencies = container.lenient(LossyDictionary<Dependency>.self, forKey: .dependencies)?.values ?? [:]
    }
}

/// `npm outdated -g --json`: one object per package, or an array when the same
/// package is outdated in several locations.
struct NPMOutdatedDTO: Decodable {
    struct Entry: Decodable {
        var current: String?
        var wanted: String?
        var latest: String?
        var location: String?

        enum CodingKeys: String, CodingKey { case current, wanted, latest, location }

        init(from decoder: Decoder) throws {
            if var array = try? decoder.unkeyedContainer() {
                self = try array.decode(Entry.self)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            current = container.lenient(String.self, forKey: .current)
            wanted = container.lenient(String.self, forKey: .wanted)
            latest = container.lenient(String.self, forKey: .latest)
            location = container.lenient(String.self, forKey: .location)
        }
    }

    var packages: [String: Entry]

    init(from decoder: Decoder) throws {
        packages = try LossyDictionary<Entry>(from: decoder).values
    }
}

/// The fields of `<root>/<name>/package.json` CLIState displays.
struct NPMPackageJSONDTO: Decodable {
    enum Bin {
        case single(String)
        case named([String: String])
    }

    var name: String?
    var description: String?
    var homepage: String?
    var bin: Bin?

    enum CodingKeys: String, CodingKey { case name, description, homepage, bin }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenient(String.self, forKey: .name)
        description = container.lenient(String.self, forKey: .description)
        homepage = container.lenient(String.self, forKey: .homepage)
        if let single = container.lenient(String.self, forKey: .bin) {
            bin = .single(single)
        } else if let named = container.lenient(LossyDictionary<String>.self, forKey: .bin) {
            bin = .named(named.values)
        }
    }
}
