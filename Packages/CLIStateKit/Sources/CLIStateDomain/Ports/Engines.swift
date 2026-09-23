import Foundation

/// Milestone 1: shell environment, PATH and binary discovery.
/// Implemented by `CLIStateDiscovery.EnvironmentDiscovery`.
public protocol EnvironmentDiscovering: Sendable {
    func discover() async throws -> DiscoveryResult
}

/// Latest-version lookup for tools without a package-manager inventory, e.g. a
/// native Claude Code install checked against npm dist-tags (C4). Read-only.
public struct UpdateSourceResult: Hashable, Codable, Sendable {
    public var sourceID: String
    public var channel: String
    public var latestVersion: String
    /// Other channels observed, e.g. `["stable": "2.1.236", "latest": "2.1.270"]`.
    public var channels: [String: String]

    public init(sourceID: String, channel: String, latestVersion: String, channels: [String: String] = [:]) {
        self.sourceID = sourceID
        self.channel = channel
        self.latestVersion = latestVersion
        self.channels = channels
    }
}

/// Milestone 3–4: attribution, merge, version detection and health analysis.
/// Implemented by `CLIStateEngine.SnapshotEngine`. Pure with respect to the UI:
/// it may run version probes through `CommandRunning` but never mutates.
public protocol SnapshotBuilding: Sendable {
    func buildSnapshot(
        discovery: DiscoveryResult,
        inventories: [ProviderInventory],
        failedProviders: [ProviderID: String],
        previous: EnvironmentSnapshot?,
        depth: ScanDepth,
        now: Date
    ) async -> EnvironmentSnapshot
}

/// Persistence port for the last snapshot (§80–§81). Application implements it
/// with an atomic JSON file (C13).
public protocol SnapshotRepository: Sendable {
    func load() async throws -> EnvironmentSnapshot?
    func save(_ snapshot: EnvironmentSnapshot) async throws
}

public protocol CommandHistoryRepository: Sendable {
    func entries(limit: Int) async throws -> [CommandHistoryEntry]
    func upsert(_ entry: CommandHistoryEntry) async throws
}
