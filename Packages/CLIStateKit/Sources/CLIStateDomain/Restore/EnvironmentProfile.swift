import Foundation

/// Which package manager an item is installed with, as written in a profile.
/// A string so a profile from a newer CLIState with providers this version
/// doesn't know still opens; unknown values are shown as "can't install".
public struct ProfileProvider: StringIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let homebrewFormula: ProfileProvider = "homebrew-formula"
    public static let homebrewCask: ProfileProvider = "homebrew-cask"
    public static let npm: ProfileProvider = "npm"
    public static let pnpm: ProfileProvider = "pnpm"
    public static let uv: ProfileProvider = "uv"
    public static let pipx: ProfileProvider = "pipx"
    public static let cargo: ProfileProvider = "cargo"

    public static let known: [ProfileProvider] = [.homebrewFormula, .homebrewCask, .npm, .pnpm, .uv, .pipx, .cargo]

    /// `nil` for providers this version can't install with.
    public init?(providerID: ProviderID, kind: PackageKind) {
        switch (providerID, kind) {
        case (.homebrew, .formula): self = .homebrewFormula
        case (.homebrew, .cask): self = .homebrewCask
        case (.npm, .globalPackage): self = .npm
        case (.pnpm, .globalPackage): self = .pnpm
        case (.uv, .tool): self = .uv
        case (.pipx, .tool): self = .pipx
        case (.cargo, .tool): self = .cargo
        default: return nil
        }
    }

    public var providerID: ProviderID? {
        switch self {
        case .homebrewFormula, .homebrewCask: .homebrew
        case .npm: .npm
        case .pnpm: .pnpm
        case .uv: .uv
        case .pipx: .pipx
        case .cargo: .cargo
        default: nil
        }
    }

    public var packageKind: PackageKind? {
        switch self {
        case .homebrewFormula: .formula
        case .homebrewCask: .cask
        case .npm, .pnpm: .globalPackage
        case .uv, .pipx, .cargo: .tool
        default: nil
        }
    }
}

/// One package to recreate. Holds no paths, environment variables or secrets.
public struct ProfileItem: Hashable, Codable, Sendable, Identifiable {
    /// Registry tool, when the package is a well-known one.
    public var toolID: ToolID?
    public var provider: ProfileProvider
    /// Provider-native name: `git`, `@anthropic-ai/claude-code`, `kimi-cli`.
    public var packageName: String
    /// Version on the machine the profile came from. Informational: installs take the latest.
    public var version: String?
    /// Pinned on the source machine (Homebrew `brew pin`). Informational in 1.0.
    public var pinned: Bool
    /// Homebrew tap the package comes from, e.g. `hashicorp/tap`. `nil` for core.
    public var tap: String?

    public init(toolID: ToolID? = nil, provider: ProfileProvider, packageName: String, version: String? = nil, pinned: Bool = false, tap: String? = nil) {
        self.toolID = toolID
        self.provider = provider
        self.packageName = packageName
        self.version = version
        self.pinned = pinned
        self.tap = tap
    }

    /// Stable within a profile: `homebrew-formula:hashicorp/tap/terraform`.
    public var id: String { "\(provider.rawValue):\(qualifiedName)" }

    /// The name handed to the package manager: tap-qualified for tapped Homebrew packages.
    public var qualifiedName: String {
        guard let tap, !tap.isEmpty, provider.providerID == .homebrew else { return packageName }
        return "\(tap)/\(packageName)"
    }

    enum CodingKeys: String, CodingKey {
        case toolID, provider, packageName, version, pinned, tap
    }

    /// Wrong-typed optional fields are ignored instead of failing the whole item.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decode(String.self, forKey: .provider).trimmingCharacters(in: .whitespacesAndNewlines)
        let packageName = try container.decode(String.self, forKey: .packageName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty, !packageName.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .packageName, in: container, debugDescription: "empty provider or package name")
        }
        self.provider = ProfileProvider(provider)
        self.packageName = packageName
        toolID = (try? container.decodeIfPresent(String.self, forKey: .toolID)).flatMap { $0.flatMap { $0.isEmpty ? nil : ToolID($0) } }
        version = (try? container.decodeIfPresent(String.self, forKey: .version)).flatMap { $0 }
        pinned = (try? container.decodeIfPresent(Bool.self, forKey: .pinned)).flatMap { $0 } ?? false
        tap = (try? container.decodeIfPresent(String.self, forKey: .tap)).flatMap { $0.flatMap { $0.isEmpty ? nil : $0 } }
    }
}

/// The Mac a profile was exported from. No host name, user name or paths.
public struct ProfileSource: Hashable, Codable, Sendable {
    /// `arm64` or `x86_64`.
    public var architecture: String?
    /// e.g. `15.6`.
    public var macOSVersion: String?
    public var appVersion: String?

    public init(architecture: String? = nil, macOSVersion: String? = nil, appVersion: String? = nil) {
        self.architecture = architecture
        self.macOSVersion = macOSVersion
        self.appVersion = appVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        architecture = (try? container.decodeIfPresent(String.self, forKey: .architecture)).flatMap { $0 }
        macOSVersion = (try? container.decodeIfPresent(String.self, forKey: .macOSVersion)).flatMap { $0 }
        appVersion = (try? container.decodeIfPresent(String.self, forKey: .appVersion)).flatMap { $0 }
    }

    enum CodingKeys: String, CodingKey { case architecture, macOSVersion, appVersion }
}

public enum EnvironmentProfileError: Error, Equatable, Sendable {
    /// Not JSON, or JSON that isn't a CLIState profile.
    case notAProfile
}

/// A portable description of the packages a developer installed on purpose,
/// saved as `.clistate-profile.json` and opened on another Mac (Lane N).
/// Versioned and tolerant: unknown keys are ignored, broken items are dropped.
public struct EnvironmentProfile: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let formatIdentifier = "clistate-profile"
    public static let fileExtension = "clistate-profile.json"

    public var format: String
    public var schemaVersion: Int
    public var createdAt: Date
    public var name: String?
    public var note: String?
    public var source: ProfileSource?
    public var items: [ProfileItem]

    public init(schemaVersion: Int = EnvironmentProfile.currentSchemaVersion, createdAt: Date, name: String? = nil, note: String? = nil, source: ProfileSource? = nil, items: [ProfileItem]) {
        self.format = Self.formatIdentifier
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.name = name
        self.note = note
        self.source = source
        self.items = items.uniquedByID()
    }

    /// Written by a newer CLIState; items this version doesn't understand show as unavailable.
    public var isNewerSchema: Bool { schemaVersion > Self.currentSchemaVersion }

    enum CodingKeys: String, CodingKey {
        case format, schemaVersion, createdAt, name, note, source, items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = (try? container.decodeIfPresent(String.self, forKey: .format)).flatMap { $0 }
        if let format, format != Self.formatIdentifier { throw EnvironmentProfileError.notAProfile }
        guard container.contains(.items) else { throw EnvironmentProfileError.notAProfile }
        self.format = Self.formatIdentifier
        schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)).flatMap { $0 } ?? 1
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)).flatMap { $0 } ?? Date(timeIntervalSince1970: 0)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)).flatMap { $0 }
        note = (try? container.decodeIfPresent(String.self, forKey: .note)).flatMap { $0 }
        source = (try? container.decodeIfPresent(ProfileSource.self, forKey: .source)).flatMap { $0 }
        let lossy = (try? container.decode(LossyItems.self, forKey: .items))?.elements ?? []
        items = lossy.uniquedByID()
    }

    // MARK: File format

    /// Pretty, key-sorted JSON with ISO 8601 dates, so profiles diff well in git.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> EnvironmentProfile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: text) { return date }
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: text) { return date }
            }
            if let seconds = try? container.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unrecognized date")
        }
        do {
            return try decoder.decode(EnvironmentProfile.self, from: data)
        } catch let error as EnvironmentProfileError {
            throw error
        } catch {
            throw EnvironmentProfileError.notAProfile
        }
    }
}

/// Decodes what it can and skips the rest.
private struct LossyItems: Decodable {
    var elements: [ProfileItem] = []

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let item = try? container.decode(ProfileItem.self) {
                elements.append(item)
            } else {
                _ = try? container.decode(Skipped.self)
            }
        }
    }

    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

extension Array where Element == ProfileItem {
    func uniquedByID() -> [ProfileItem] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Templates

/// A curated starting point (前端 Web, Go 后端 …). Titles and descriptions are
/// localized in the App from `id`.
public struct EnvironmentTemplate: Hashable, Sendable, Identifiable {
    public var id: String
    public var items: [ProfileItem]

    public init(id: String, items: [ProfileItem]) {
        self.id = id
        self.items = items
    }

    public var profile: EnvironmentProfile {
        EnvironmentProfile(createdAt: Date(timeIntervalSince1970: 0), name: id, items: items)
    }
}

/// A registry tool CLIState knows how to install, with its preferred package.
/// Also the whitelist AI suggestions are filtered against.
public struct RestoreCandidate: Hashable, Sendable, Identifiable {
    public var toolID: ToolID
    public var displayName: String
    /// English registry summary; the App localizes by `toolID`.
    public var summary: String
    public var category: ToolCategory
    public var item: ProfileItem

    public var id: ToolID { toolID }

    public init(toolID: ToolID, displayName: String, summary: String, category: ToolCategory, item: ProfileItem) {
        self.toolID = toolID
        self.displayName = displayName
        self.summary = summary
        self.category = category
        self.item = item
    }
}

// MARK: - Diff

/// Why an item can't be installed on this Mac.
public enum RestoreBlocker: Hashable, Sendable {
    /// The package manager isn't installed, and nothing selected installs it.
    case providerMissing(ProviderID)
    /// A provider value this version doesn't know.
    case unsupportedProvider(String)
    /// The name could be read as an option or a path; never passed to a package manager.
    case invalidPackageName
}

public enum ProfileItemStatus: Hashable, Sendable {
    /// Installed with the same or a newer version. `provider` may differ from the
    /// profile's (e.g. Node.js via nvm instead of Homebrew); it is not reinstalled.
    case installed(version: String?, provider: ProviderID)
    /// Installed, but older than on the source Mac. Informational: CLIState never downgrades or upgrades here.
    case versionDiffers(installed: String, expected: String, provider: ProviderID)
    /// Can be installed now.
    case pending
    /// Can be installed once an earlier step installs its package manager (npm after Node.js).
    case pendingAfter(provider: ProviderID, enabledBy: [ToolID])
    case unavailable(RestoreBlocker)

    public var isInstalled: Bool {
        switch self {
        case .installed, .versionDiffers: true
        default: false
        }
    }

    public var isInstallable: Bool {
        switch self {
        case .pending, .pendingAfter: true
        default: false
        }
    }
}

public struct ProfileDiffEntry: Hashable, Sendable, Identifiable {
    public var item: ProfileItem
    public var status: ProfileItemStatus

    public var id: String { item.id }

    public init(item: ProfileItem, status: ProfileItemStatus) {
        self.item = item
        self.status = status
    }
}

public struct ProfileDiff: Hashable, Sendable {
    public var entries: [ProfileDiffEntry]

    public init(entries: [ProfileDiffEntry]) {
        self.entries = entries
    }

    public var installed: [ProfileDiffEntry] { entries.filter { if case .installed = $0.status { true } else { false } } }
    public var versionDiffers: [ProfileDiffEntry] { entries.filter { if case .versionDiffers = $0.status { true } else { false } } }
    public var installable: [ProfileDiffEntry] { entries.filter(\.status.isInstallable) }
    public var unavailable: [ProfileDiffEntry] { entries.filter { if case .unavailable = $0.status { true } else { false } } }
}

// MARK: - Staged install

/// Selected packages of one provider, in install order.
public struct RestoreProviderGroup: Hashable, Sendable, Identifiable {
    public var provider: ProviderID
    public var items: [ProfileItem]
    /// Registry tools earlier in the plan that install this provider (for deferred groups).
    public var enabledBy: [ToolID]

    public var id: ProviderID { provider }

    public init(provider: ProviderID, items: [ProfileItem], enabledBy: [ToolID] = []) {
        self.provider = provider
        self.items = items
        self.enabledBy = enabledBy
    }

    public var requests: [InstallRequest] { items.map(InstallRequest.init(item:)) }
}

/// What to install now, what has to wait for an earlier step, and what can't run.
/// Homebrew goes first so runtimes exist before npm, uv, pipx and cargo need them;
/// deferred groups are planned again after the rescan that follows each stage.
public struct RestoreStagePlan: Hashable, Sendable {
    public var ready: [RestoreProviderGroup]
    public var deferred: [RestoreProviderGroup]
    public var blocked: [RestoreProviderGroup]

    public init(ready: [RestoreProviderGroup] = [], deferred: [RestoreProviderGroup] = [], blocked: [RestoreProviderGroup] = []) {
        self.ready = ready
        self.deferred = deferred
        self.blocked = blocked
    }

    public var isEmpty: Bool { ready.isEmpty && deferred.isEmpty && blocked.isEmpty }
}
