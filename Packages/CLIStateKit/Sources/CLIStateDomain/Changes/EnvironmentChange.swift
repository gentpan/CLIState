import Foundation

/// What changed between two scans. The App renders localized text from the kind
/// and the change's parameters.
public enum EnvironmentChangeKind: String, Codable, Sendable, CaseIterable {
    case toolAdded
    case toolRemoved
    case installationAdded
    case installationRemoved
    /// Same installation (or the only installation of a version-managed tool) at a new version.
    case versionChanged
    /// The command now resolves to a different executable or installation.
    case activeExecutableChanged
    /// The same tool is now provided by a different package manager or installer.
    case providerChanged
    case pathEntryAdded
    case pathEntryRemoved
    case pathEntryMoved
    case serviceStarted
    case serviceStopped
    /// Many unrecognized executables appeared at once; collapsed into a count.
    case unrecognizedToolsAdded
    case unrecognizedToolsRemoved
}

/// Who caused a change, correlated with `CommandHistoryEntry` rows.
public struct ChangeOrigin: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// An operation CLIState ran (update, uninstall, move to Trash…).
        case clistate
        /// Anything else, e.g. `brew upgrade` typed in Terminal.
        case external
    }

    public var kind: Kind
    public var historyEntryID: UUID?
    public var operation: OperationKind?
    public var trigger: OperationTrigger?

    public init(kind: Kind, historyEntryID: UUID? = nil, operation: OperationKind? = nil, trigger: OperationTrigger? = nil) {
        self.kind = kind
        self.historyEntryID = historyEntryID
        self.operation = operation
        self.trigger = trigger
    }

    public static let external = ChangeOrigin(kind: .external)
}

/// One language-neutral change. Tool names are kept so removed tools can still be shown.
public struct EnvironmentChange: Identifiable, Hashable, Codable, Sendable {
    /// Stable within one event: `<kind>:<subject>`.
    public var id: String
    public var kind: EnvironmentChangeKind
    public var toolID: ToolID?
    /// Registry or provider display name at the time of the change.
    public var toolName: String?
    public var category: ToolCategory?
    public var installationID: InstallationID?
    public var provider: ProviderID?
    public var previousProvider: ProviderID?
    /// Version, path or PATH priority before the change.
    public var from: String?
    /// Version, path or PATH priority after the change.
    public var to: String?
    /// Command name, PATH entry or service name the change is about.
    public var subject: String?
    public var count: Int?
    /// A few example names for collapsed changes.
    public var names: [String]
    public var origin: ChangeOrigin

    public init(
        kind: EnvironmentChangeKind,
        toolID: ToolID? = nil,
        toolName: String? = nil,
        category: ToolCategory? = nil,
        installationID: InstallationID? = nil,
        provider: ProviderID? = nil,
        previousProvider: ProviderID? = nil,
        from: String? = nil,
        to: String? = nil,
        subject: String? = nil,
        count: Int? = nil,
        names: [String] = [],
        origin: ChangeOrigin = .external
    ) {
        let key = installationID?.rawValue ?? toolID?.rawValue ?? subject ?? ""
        self.id = "\(kind.rawValue):\(key)"
        self.kind = kind
        self.toolID = toolID
        self.toolName = toolName
        self.category = category
        self.installationID = installationID
        self.provider = provider
        self.previousProvider = previousProvider
        self.from = from
        self.to = to
        self.subject = subject
        self.count = count
        self.names = names
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, toolID, toolName, category, installationID, provider, previousProvider, from, to, subject, count, names, origin
    }

    /// Unknown categories or origins from a newer version degrade instead of failing the row.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(EnvironmentChangeKind.self, forKey: .kind)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? kind.rawValue
        toolID = try? container.decodeIfPresent(ToolID.self, forKey: .toolID)
        toolName = try? container.decodeIfPresent(String.self, forKey: .toolName)
        category = try? container.decodeIfPresent(ToolCategory.self, forKey: .category)
        installationID = try? container.decodeIfPresent(InstallationID.self, forKey: .installationID)
        provider = try? container.decodeIfPresent(ProviderID.self, forKey: .provider)
        previousProvider = try? container.decodeIfPresent(ProviderID.self, forKey: .previousProvider)
        from = try? container.decodeIfPresent(String.self, forKey: .from)
        to = try? container.decodeIfPresent(String.self, forKey: .to)
        subject = try? container.decodeIfPresent(String.self, forKey: .subject)
        count = try? container.decodeIfPresent(Int.self, forKey: .count)
        names = (try? container.decodeIfPresent([String].self, forKey: .names)) ?? []
        origin = (try? container.decodeIfPresent(ChangeOrigin.self, forKey: .origin)) ?? .external
    }
}

/// Changes detected by one scan, compared with the snapshot before it.
public struct EnvironmentChangeEvent: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var detectedAt: Date
    /// Capture time of the snapshot this one was compared with; changes happened in between.
    public var previousCapturedAt: Date?
    public var depth: ScanDepth
    /// First recorded scan: nothing to compare with, so no changes are listed.
    public var isBaseline: Bool
    /// Tools in the snapshot, shown on the baseline row.
    public var toolCount: Int
    public var changes: [EnvironmentChange]

    public init(id: UUID = UUID(), detectedAt: Date, previousCapturedAt: Date? = nil, depth: ScanDepth, isBaseline: Bool = false, toolCount: Int = 0, changes: [EnvironmentChange]) {
        self.id = id
        self.detectedAt = detectedAt
        self.previousCapturedAt = previousCapturedAt
        self.depth = depth
        self.isBaseline = isBaseline
        self.toolCount = toolCount
        self.changes = changes
    }

    private enum CodingKeys: String, CodingKey {
        case id, detectedAt, previousCapturedAt, depth, isBaseline, toolCount, changes
    }

    /// Skips individual changes it can't read (e.g. a kind added by a newer version).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        detectedAt = try container.decode(Date.self, forKey: .detectedAt)
        previousCapturedAt = try? container.decodeIfPresent(Date.self, forKey: .previousCapturedAt)
        depth = (try? container.decodeIfPresent(ScanDepth.self, forKey: .depth)) ?? .fast
        isBaseline = (try? container.decodeIfPresent(Bool.self, forKey: .isBaseline)) ?? false
        toolCount = (try? container.decodeIfPresent(Int.self, forKey: .toolCount)) ?? 0
        let lossy = (try? container.decodeIfPresent([LossyElement<EnvironmentChange>].self, forKey: .changes)) ?? []
        changes = lossy.compactMap(\.value)
    }
}

/// Decodes an element or `nil`, so one bad row doesn't drop the whole array.
public struct LossyElement<Value: Decodable & Sendable>: Decodable, Sendable {
    public let value: Value?

    public init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Bounded, append-only timeline of environment changes.
public protocol EnvironmentChangeRepository: Sendable {
    /// Newest first.
    func events(since: Date?) async -> [EnvironmentChangeEvent]
    func append(_ event: EnvironmentChangeEvent) async
    /// Whether any event (including a baseline) was ever recorded.
    func hasEvents() async -> Bool
}
