import Foundation

public enum HealthSeverity: String, Codable, Sendable, Comparable {
    case info, warning, critical

    private var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .critical: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public enum HealthIssueType: String, Codable, Sendable {
    /// Different providers compete for the same active command.
    case pathConflict
    /// Several installations of one tool (same provider or intentional).
    case duplicateInstallation
    case missingPathEntry
    case duplicatePathEntry
    case relativePathEntry
    /// e.g. `npm` resolves but `node` does not.
    case missingRuntime
    case brokenSymlink
    case brokenActiveExecutable
    case failedService
    case providerUnavailable
    case providerScanFailed
    case mixedArchitecture
    case shellShadowing
    /// A runtime or database release cycle is past, or close to, its end of life.
    case runtimeEndOfLife
}

public enum SuggestedAction: Hashable, Codable, Sendable {
    case openPathSettings
    case revealInFinder(String)
    case updateTool(ToolID)
    case restartService(String)
    /// Opens the tool's detail.
    case openTool(ToolID)
    case none
}

/// Language-neutral issue. The UI renders localized title/message from `type`
/// plus `subject` and `details`, so Domain stays free of display strings.
public struct HealthIssue: Identifiable, Hashable, Codable, Sendable {
    /// Stable across scans: `<type>:<subject>`.
    public var id: String
    public var type: HealthIssueType
    public var severity: HealthSeverity
    /// Main parameter, e.g. `node`, a PATH entry, or a service name.
    public var subject: String
    public var toolID: ToolID?
    public var installationIDs: [InstallationID]
    public var paths: [String]
    public var details: [String: String]
    public var suggestedAction: SuggestedAction?

    public init(type: HealthIssueType, severity: HealthSeverity, subject: String, toolID: ToolID? = nil, installationIDs: [InstallationID] = [], paths: [String] = [], details: [String: String] = [:], suggestedAction: SuggestedAction? = nil) {
        self.id = "\(type.rawValue):\(subject)"
        self.type = type
        self.severity = severity
        self.subject = subject
        self.toolID = toolID
        self.installationIDs = installationIDs
        self.paths = paths
        self.details = details
        self.suggestedAction = suggestedAction
    }
}

public enum EnvironmentHealth: String, Codable, Sendable {
    case good
    case attention
    case issuesFound

    /// Updates never affect health (C7); info issues don't either.
    public static func evaluate(_ issues: [HealthIssue]) -> EnvironmentHealth {
        let worst = issues.map(\.severity).max() ?? .info
        switch worst {
        case .critical: return .issuesFound
        case .warning: return .attention
        case .info: return .good
        }
    }
}

public enum Freshness: Hashable, Codable, Sendable {
    case fresh(Date)
    /// Last successful data kept after a failed refresh (§219, §220).
    case stale(Date)
    case unavailable
    case unknown
}

public struct ProviderSnapshot: Hashable, Codable, Sendable {
    public var providerID: ProviderID
    public var availability: ProviderAvailability
    public var instance: ProviderInstance?
    public var layout: ProviderLayout
    public var freshness: Freshness
    public var toolCount: Int
    public var serviceCount: Int
    public var latestCheckedAt: Date?
    public var lastError: String?
    public var warnings: [String]
    /// When the local package index behind `latestCheckedAt` was downloaded, e.g. by
    /// `brew update`. A check can be minutes old while its data is hours old.
    public var metadataUpdatedAt: Date?

    public init(providerID: ProviderID, availability: ProviderAvailability, instance: ProviderInstance? = nil, layout: ProviderLayout = ProviderLayout(), freshness: Freshness, toolCount: Int = 0, serviceCount: Int = 0, latestCheckedAt: Date? = nil, lastError: String? = nil, warnings: [String] = [], metadataUpdatedAt: Date? = nil) {
        self.providerID = providerID
        self.availability = availability
        self.instance = instance
        self.layout = layout
        self.freshness = freshness
        self.toolCount = toolCount
        self.serviceCount = serviceCount
        self.latestCheckedAt = latestCheckedAt
        self.lastError = lastError
        self.warnings = warnings
        self.metadataUpdatedAt = metadataUpdatedAt
    }
}

/// The single source every screen renders from (§217). Replaced atomically (§218).
public struct EnvironmentSnapshot: Identifiable, Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var hostID: HostID
    public var capturedAt: Date
    public var depth: ScanDepth
    public var shell: ShellEnvironment
    public var pathEntries: [PATHEntry]
    public var brokenSymlinks: [BrokenSymlink]
    public var providers: [ProviderSnapshot]
    public var tools: [Tool]
    public var services: [ToolService]
    public var issues: [HealthIssue]
    /// Probe results keyed by resolved executable path; reused while size and
    /// modification date are unchanged so fast scans don't re-run `--version`.
    public var versionCache: [String: CachedVersion]
    public var cleanupCandidates: [CleanupCandidate]
    /// When the latest versions this snapshot carries were checked by a completed deep
    /// scan. Fast scans keep the previous value; `nil` in snapshots saved before it existed.
    public var latestCheckedAt: Date?

    public init(
        schemaVersion: Int = EnvironmentSnapshot.currentSchemaVersion,
        id: UUID = UUID(),
        hostID: HostID = .local,
        capturedAt: Date,
        depth: ScanDepth,
        shell: ShellEnvironment,
        pathEntries: [PATHEntry],
        brokenSymlinks: [BrokenSymlink],
        providers: [ProviderSnapshot],
        tools: [Tool],
        services: [ToolService],
        issues: [HealthIssue],
        versionCache: [String: CachedVersion] = [:],
        cleanupCandidates: [CleanupCandidate] = [],
        latestCheckedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.hostID = hostID
        self.capturedAt = capturedAt
        self.depth = depth
        self.shell = shell
        self.pathEntries = pathEntries
        self.brokenSymlinks = brokenSymlinks
        self.providers = providers
        self.tools = tools
        self.services = services
        self.issues = issues
        self.versionCache = versionCache
        self.cleanupCandidates = cleanupCandidates
        self.latestCheckedAt = latestCheckedAt
    }

    public var health: EnvironmentHealth { EnvironmentHealth.evaluate(issues) }

    public func tool(_ id: ToolID) -> Tool? { tools.first { $0.id == id } }
}

public struct CachedVersion: Hashable, Codable, Sendable {
    public var version: String?
    public var size: Int64?
    public var modifiedAt: Date?
    /// The exact probe that produced it, e.g. `php --version`.
    public var probe: String
    /// When the probe ran the executable. Its access time from then is CLI State's,
    /// not a use. `nil` in snapshots saved before it existed.
    public var probedAt: Date?

    public init(version: String?, size: Int64?, modifiedAt: Date?, probe: String, probedAt: Date? = nil) {
        self.version = version
        self.size = size
        self.modifiedAt = modifiedAt
        self.probe = probe
        self.probedAt = probedAt
    }
}
