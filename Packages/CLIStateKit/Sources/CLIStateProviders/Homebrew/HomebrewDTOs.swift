import Foundation

// Raw shapes of Homebrew's JSON. Every field is optional and unknown keys are
// ignored so a new Homebrew release cannot break the scan (§175). DTOs never
// leave this target; `HomebrewMapper` turns them into `ProviderTool`s.

/// `brew info --json=v2 --installed`
struct BrewInfoDTO: Decodable {
    var formulae: [BrewFormulaDTO]
    var casks: [BrewCaskDTO]

    enum CodingKeys: String, CodingKey { case formulae, casks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formulae = container.lenient(LossyArray<BrewFormulaDTO>.self, forKey: .formulae)?.elements ?? []
        casks = container.lenient(LossyArray<BrewCaskDTO>.self, forKey: .casks)?.elements ?? []
    }
}

struct BrewFormulaDTO: Decodable {
    struct Versions: Decodable {
        var stable: String?
    }

    struct Installed: Decodable {
        var version: String?
        var time: Double?
        var installedOnRequest: Bool?

        enum CodingKeys: String, CodingKey {
            case version, time
            case installedOnRequest = "installed_on_request"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = container.lenient(String.self, forKey: .version)
            time = container.lenient(Double.self, forKey: .time)
            installedOnRequest = container.lenient(Bool.self, forKey: .installedOnRequest)
        }
    }

    var name: String
    var fullName: String?
    var desc: String?
    var homepage: String?
    var versions: Versions?
    var revision: Int?
    var kegOnly: Bool?
    var dependencies: [String]
    var installed: [Installed]
    var linkedKeg: String?
    var pinned: Bool?
    var outdated: Bool?

    enum CodingKeys: String, CodingKey {
        case name, desc, homepage, versions, revision, dependencies, installed, pinned, outdated
        case fullName = "full_name"
        case kegOnly = "keg_only"
        case linkedKeg = "linked_keg"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        fullName = container.lenient(String.self, forKey: .fullName)
        desc = container.lenient(String.self, forKey: .desc)
        homepage = container.lenient(String.self, forKey: .homepage)
        versions = container.lenient(Versions.self, forKey: .versions)
        revision = container.lenient(Int.self, forKey: .revision)
        kegOnly = container.lenient(Bool.self, forKey: .kegOnly)
        dependencies = container.lenient(LossyArray<String>.self, forKey: .dependencies)?.elements ?? []
        installed = container.lenient(LossyArray<Installed>.self, forKey: .installed)?.elements ?? []
        linkedKeg = container.lenient(String.self, forKey: .linkedKeg)
        pinned = container.lenient(Bool.self, forKey: .pinned)
        outdated = container.lenient(Bool.self, forKey: .outdated)
    }
}

struct BrewCaskDTO: Decodable {
    /// One `artifacts[]` entry. Only `binary` matters for CLI attribution (F7).
    struct Artifact: Decodable {
        var binary: [BinaryEntry]?
        /// Absolute link path Homebrew created, e.g. `/opt/homebrew/bin/codexbar`.
        var target: String?

        enum CodingKeys: String, CodingKey { case binary, target }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            binary = container.lenient(LossyArray<BinaryEntry>.self, forKey: .binary)?.elements
            target = container.lenient(String.self, forKey: .target)
        }
    }

    /// `"binary": ["<source>", {"target": "codexbar"}]`
    enum BinaryEntry: Decodable {
        case source(String)
        case options(target: String?)

        enum CodingKeys: String, CodingKey { case target }

        init(from decoder: Decoder) throws {
            if let source = try? decoder.singleValueContainer().decode(String.self) {
                self = .source(source)
            } else {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self = .options(target: container.lenient(String.self, forKey: .target))
            }
        }
    }

    var token: String
    var fullToken: String?
    var names: [String]
    var desc: String?
    var homepage: String?
    var version: String?
    var installed: String?
    var installedTime: Double?
    var outdated: Bool?
    var pinned: Bool?
    var artifacts: [Artifact]

    enum CodingKeys: String, CodingKey {
        case token, desc, homepage, version, installed, outdated, pinned, artifacts
        case names = "name"
        case fullToken = "full_token"
        case installedTime = "installed_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        fullToken = container.lenient(String.self, forKey: .fullToken)
        names = container.lenient(LossyArray<String>.self, forKey: .names)?.elements ?? []
        desc = container.lenient(String.self, forKey: .desc)
        homepage = container.lenient(String.self, forKey: .homepage)
        version = container.lenient(String.self, forKey: .version)
        installed = container.lenient(String.self, forKey: .installed)
        installedTime = container.lenient(Double.self, forKey: .installedTime)
        outdated = container.lenient(Bool.self, forKey: .outdated)
        pinned = container.lenient(Bool.self, forKey: .pinned)
        artifacts = container.lenient(LossyArray<Artifact>.self, forKey: .artifacts)?.elements ?? []
    }
}

/// `brew outdated --json=v2`
struct BrewOutdatedDTO: Decodable {
    struct Entry: Decodable {
        var name: String
        var installedVersions: [String]
        var currentVersion: String?
        var pinned: Bool?
        var pinnedVersion: String?

        enum CodingKeys: String, CodingKey {
            case name, pinned
            case installedVersions = "installed_versions"
            case currentVersion = "current_version"
            case pinnedVersion = "pinned_version"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            installedVersions = container.lenient(LossyArray<String>.self, forKey: .installedVersions)?.elements ?? []
            currentVersion = container.lenient(String.self, forKey: .currentVersion)
            pinned = container.lenient(Bool.self, forKey: .pinned)
            pinnedVersion = container.lenient(String.self, forKey: .pinnedVersion)
        }
    }

    var formulae: [Entry]
    var casks: [Entry]

    enum CodingKeys: String, CodingKey { case formulae, casks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formulae = container.lenient(LossyArray<Entry>.self, forKey: .formulae)?.elements ?? []
        casks = container.lenient(LossyArray<Entry>.self, forKey: .casks)?.elements ?? []
    }
}

/// One element of `brew services list --json`.
struct BrewServiceDTO: Decodable {
    var name: String
    var status: String?
    var user: String?
    var file: String?
    var exitCode: Int?

    enum CodingKeys: String, CodingKey {
        case name, status, user, file
        case exitCode = "exit_code"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        status = container.lenient(String.self, forKey: .status)
        user = container.lenient(String.self, forKey: .user)
        file = container.lenient(String.self, forKey: .file)
        exitCode = container.lenient(Int.self, forKey: .exitCode)
    }
}
