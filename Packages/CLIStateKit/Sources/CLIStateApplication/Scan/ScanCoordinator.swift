import CLIStateDomain
import Foundation

/// Orchestrates a scan without doing any of the work itself (§68.1): discovery,
/// providers in parallel, snapshot building, persistence. A newer full scan
/// cancels an older one (§90); providers failing individually never fail the scan (§219).
public actor ScanCoordinator {
    public enum Event: Sendable {
        case started(ScanDepth)
        case phase(ScanPhase)
        case finished(EnvironmentSnapshot)
        case failed(String)
    }

    public enum ScanPhase: String, Sendable {
        case discoveringEnvironment, scanningProviders, buildingSnapshot, saving
    }

    private let discovery: any EnvironmentDiscovering
    private let providers: [any ToolProvider]
    private let builder: any SnapshotBuilding
    private let repository: any SnapshotRepository
    private let clock: @Sendable () -> Date
    private let recorder: (any ScanRecording)?

    private var current: EnvironmentSnapshot?
    private var lastDiscovery: DiscoveryResult?
    private var lastInventories: [ProviderID: ProviderInventory] = [:]
    private var running: (id: UUID, task: Task<EnvironmentSnapshot?, Never>)?
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    public init(
        discovery: any EnvironmentDiscovering,
        providers: [any ToolProvider],
        builder: any SnapshotBuilding,
        repository: any SnapshotRepository,
        clock: @escaping @Sendable () -> Date = { Date() },
        recorder: (any ScanRecording)? = nil
    ) {
        self.discovery = discovery
        self.providers = providers
        self.builder = builder
        self.repository = repository
        self.clock = clock
        self.recorder = recorder
    }

    // MARK: Observation

    public func events() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(_ event: Event) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    // MARK: Reading state

    public var snapshot: EnvironmentSnapshot? { current }
    public var discoveryResult: DiscoveryResult? { lastDiscovery }

    /// Loads the cached snapshot so the UI can render before the first scan (§162).
    @discardableResult
    public func loadCached() async -> EnvironmentSnapshot? {
        if current == nil, let cached = try? await repository.load() {
            current = cached
            emit(.finished(cached))
        }
        return current
    }

    public func inventory(for provider: ProviderID) -> ProviderInventory? { lastInventories[provider] }

    public func providerTool(for installationID: InstallationID) -> ProviderTool? {
        for inventory in lastInventories.values {
            if let tool = inventory.tools.first(where: { $0.installationID == installationID }) { return tool }
        }
        return nil
    }

    public func provider(_ id: ProviderID) -> (any ToolProvider)? {
        providers.first { $0.id == id }
    }

    /// Providers that can refresh their package metadata, e.g. Homebrew.
    public var metadataRefreshProviderIDs: [ProviderID] {
        providers.compactMap { ($0 as? any MetadataRefreshProvider)?.id }
    }

    // MARK: Scanning

    /// Starts a scan, cancelling any scan in progress, and returns its snapshot
    /// (`nil` if this scan was itself superseded).
    @discardableResult
    public func scan(depth: ScanDepth) async -> EnvironmentSnapshot? {
        running?.task.cancel()
        let id = UUID()
        let task = Task { await self.performScan(depth: depth) }
        running = (id, task)
        let result = await task.value
        if running?.id == id { running = nil }
        return result
    }

    private func performScan(depth: ScanDepth) async -> EnvironmentSnapshot? {
        emit(.started(depth))
        do {
            emit(.phase(.discoveringEnvironment))
            let discovered = try await discovery.discover()
            try Task.checkCancellation()

            emit(.phase(.scanningProviders))
            let context = ProviderContext(discovery: discovered, now: clock())
            let (inventories, failures) = await scanProviders(context: context, depth: depth)
            try Task.checkCancellation()

            emit(.phase(.buildingSnapshot))
            let snapshot = await builder.buildSnapshot(
                discovery: discovered,
                inventories: inventories,
                failedProviders: failures,
                previous: current,
                depth: depth,
                now: clock()
            )
            try Task.checkCancellation()

            emit(.phase(.saving))
            // The change timeline compares with the persisted snapshot even when the cache wasn't loaded first.
            var previous = current
            if previous == nil, recorder != nil { previous = try? await repository.load() }
            current = snapshot
            lastDiscovery = discovered
            for inventory in inventories { lastInventories[inventory.providerID] = inventory }
            try? await repository.save(snapshot)
            await recorder?.scanFinished(previous: previous, current: snapshot)
            emit(.finished(snapshot))
            MemoryRelief.releaseFreedPages()
            return snapshot
        } catch is CancellationError {
            return nil
        } catch {
            emit(.failed(String(describing: error)))
            return nil
        }
    }

    private func scanProviders(context: ProviderContext, depth: ScanDepth) async -> ([ProviderInventory], [ProviderID: String]) {
        await withTaskGroup(of: (ProviderID, Result<ProviderInventory?, Error>).self) { group in
            for provider in providers {
                group.addTask {
                    let availability = await provider.availability(context: context)
                    guard availability.isAvailable else {
                        return (provider.id, .success(ProviderInventory(providerID: provider.id, availability: availability, depth: depth, scannedAt: context.now)))
                    }
                    do {
                        return (provider.id, .success(try await provider.scan(context: context, depth: depth)))
                    } catch {
                        return (provider.id, .failure(error))
                    }
                }
            }
            var inventories: [ProviderInventory] = []
            var failures: [ProviderID: String] = [:]
            for await (id, result) in group {
                switch result {
                case let .success(inventory?): inventories.append(inventory)
                case .success(nil): break
                case let .failure(error): failures[id] = Self.failureSummary(error)
                }
            }
            return (inventories.sorted { $0.providerID < $1.providerID }, failures)
        }
    }

    /// Provider errors can carry a command's whole stderr; the snapshot (and its JSON
    /// file) keeps the start, which names the command and the error.
    static let failureSummaryLimit = 2_000

    static func failureSummary(_ error: any Error) -> String {
        let text = String(describing: error)
        guard text.count > failureSummaryLimit else { return text }
        return String(text.prefix(failureSummaryLimit)) + "…"
    }

    // MARK: Cleanup

    /// Runs provider dry-runs on demand (they are slower than a scan) and merges
    /// them with engine-side candidates already in the snapshot.
    public func refreshCleanupCandidates() async -> [CleanupCandidate] {
        guard let discovered = lastDiscovery, let original = current else { return current?.cleanupCandidates ?? [] }
        let scanID = running?.id
        let context = ProviderContext(discovery: discovered, now: clock())
        let providerCandidates = await withTaskGroup(of: [CleanupCandidate].self) { group in
            for case let provider as any CleanupProvider in providers {
                group.addTask { (try? await provider.cleanupCandidates(context: context)) ?? [] }
            }
            var all: [CleanupCandidate] = []
            for await candidates in group { all.append(contentsOf: candidates) }
            return all
        }
        // A full scan may complete or start while the dry runs suspend this actor.
        // Its environment and candidates supersede this preview.
        guard var snapshot = current, snapshot.id == original.id, running?.id == scanID else {
            return current?.cleanupCandidates ?? []
        }
        let providerIDs = Set(providerCandidates.map(\.id))
        // Engine suggestions can also have a known provider (e.g. Homebrew links or nvm runtimes).
        let engineCandidates = snapshot.cleanupCandidates.filter {
            ($0.kind == .brokenSymlink || $0.kind == .unusedRuntime || $0.providerID == nil) && !providerIDs.contains($0.id)
        }
        snapshot.cleanupCandidates = (providerCandidates + engineCandidates).sorted { $0.id < $1.id }
        current = snapshot
        try? await repository.save(snapshot)
        guard current?.id == snapshot.id, running?.id == scanID else {
            return current?.cleanupCandidates ?? []
        }
        emit(.finished(snapshot))
        return snapshot.cleanupCandidates
    }
}
