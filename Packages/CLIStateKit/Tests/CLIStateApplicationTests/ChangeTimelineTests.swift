@testable import CLIStateApplication
import CLIStateDomain
import CLIStateEngine
import Foundation
import Testing

private let start = Date(timeIntervalSince1970: 1_789_000_000)

/// Shared mutable clock for actors under test.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func advance(days: Double) { now = now.addingTimeInterval(days * 86400) }
}

private func temporaryFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("clistate-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name)
}

private func change(_ index: Int) -> EnvironmentChange {
    EnvironmentChange(kind: .versionChanged, toolID: ToolID("tool\(index)"), installationID: InstallationID("homebrew:tool\(index)"), from: "1.0", to: "1.1")
}

@Suite("Change timeline store and recorder")
struct ChangeTimelineTests {
    // MARK: Store

    @Test func storePersistsAtomicallyAndReloads() async throws {
        let url = temporaryFile("changes.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = TestClock(start)
        let store = JSONChangeEventStore(fileURL: url, clock: { clock.now })
        #expect(await store.hasEvents() == false)
        await store.append(EnvironmentChangeEvent(detectedAt: start, depth: .fast, isBaseline: true, toolCount: 42, changes: []))
        await store.append(EnvironmentChangeEvent(detectedAt: start.addingTimeInterval(60), previousCapturedAt: start, depth: .deep, changes: [change(1)]))

        let reopened = JSONChangeEventStore(fileURL: url, clock: { clock.now })
        let events = await reopened.events(since: nil)
        #expect(events.count == 2)
        #expect(events.first?.changes.first?.to == "1.1")
        #expect(events.last?.isBaseline == true)
        #expect(events.last?.toolCount == 42)
        #expect(await reopened.events(since: start.addingTimeInterval(30)).count == 1)
        #expect(try JSONChangeEventStore.readEvents(fileURL: url).count == 2)
    }

    @Test func storeDropsEventsOlderThan180Days() async {
        let clock = TestClock(start)
        let store = JSONChangeEventStore(fileURL: nil, clock: { clock.now })
        await store.append(EnvironmentChangeEvent(detectedAt: start, depth: .fast, isBaseline: true, changes: []))
        await store.append(EnvironmentChangeEvent(detectedAt: start.addingTimeInterval(86400), depth: .fast, changes: [change(1)]))
        clock.advance(days: 182)
        await store.append(EnvironmentChangeEvent(detectedAt: clock.now, depth: .fast, changes: [change(2)]))
        let events = await store.events(since: nil)
        #expect(events.map { $0.changes.first?.toolID } == ["tool2"])
        // The baseline itself aged out, but the timeline still isn't new.
        #expect(await store.hasEvents())
    }

    @Test func storeCapsTotalChangesOldestFirst() async {
        let store = JSONChangeEventStore(fileURL: nil, maxChanges: 10, clock: { start })
        for batch in 0..<4 {
            await store.append(EnvironmentChangeEvent(detectedAt: start.addingTimeInterval(Double(batch)), depth: .fast, changes: (0..<4).map { change(batch * 10 + $0) }))
        }
        let events = await store.events(since: nil)
        #expect(events.reduce(0) { $0 + $1.changes.count } <= 10)
        #expect(events.count == 2)
        #expect(events.first?.changes.first?.toolID == "tool30")

        await store.append(EnvironmentChangeEvent(detectedAt: start.addingTimeInterval(10), depth: .fast, changes: (0..<25).map(change)))
        let oversized = await store.events(since: nil)
        #expect(oversized.count == 1)
        #expect(oversized.first?.changes.count == 10)
    }

    @Test func storeToleratesUnreadableRowsAndQuarantinesGarbage() async throws {
        let url = temporaryFile("changes.json")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        {"version":2,"baselineAt":"2026-09-01T00:00:00Z","events":[
          {"id":"not-a-uuid","detectedAt":"2026-09-02T00:00:00Z"},
          {"id":"8B1B0F52-8E7A-4A4B-9D57-9C0A3C1B2D11","detectedAt":"2026-09-03T00:00:00Z","depth":"fast","changes":[{"kind":"versionChanged","toolID":"node"}],"extra":true}
        ]}
        """.utf8).write(to: url)
        let clock = TestClock(Date(timeIntervalSince1970: 1_789_000_000))
        let store = JSONChangeEventStore(fileURL: url, clock: { clock.now })
        #expect(await store.events(since: nil).count == 1)

        try Data("not json".utf8).write(to: url)
        let broken = JSONChangeEventStore(fileURL: url, clock: { clock.now })
        #expect(await broken.events(since: nil).isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("changes.corrupt.json").path))
        // Still works in memory, then writes a fresh file.
        await broken.append(EnvironmentChangeEvent(detectedAt: clock.now, depth: .fast, isBaseline: true, changes: []))
        #expect(try JSONChangeEventStore.readEvents(fileURL: url).count == 1)
    }

    @Test func unwritableLocationFallsBackToMemory() async {
        let store = JSONChangeEventStore(fileURL: URL(fileURLWithPath: "/dev/null/changes.json"), clock: { start })
        await store.append(EnvironmentChangeEvent(detectedAt: start, depth: .fast, changes: [change(1)]))
        #expect(await store.events(since: nil).count == 1)
    }

    // MARK: Recorder

    @Test func firstScanRecordsOnlyABaseline() async {
        let store = JSONChangeEventStore(fileURL: nil, clock: { start })
        let recorder = EnvironmentChangeRecorder(store: store, history: FakeHistory())
        let snapshot = timelineSnapshot(nodeVersion: "24.1.0", at: start)
        // The first scan is the baseline; an identical rescan adds nothing.
        await recorder.scanFinished(previous: nil, current: snapshot)
        await recorder.scanFinished(previous: snapshot, current: snapshot)
        let events = await store.events(since: nil)
        #expect(events.count == 1)
        #expect(events.first?.isBaseline == true)
        #expect(events.first?.toolCount == 1)
    }

    @Test func laterScansRecordAttributedChanges() async throws {
        let store = JSONChangeEventStore(fileURL: nil, clock: { start })
        let history = FakeHistory()
        let recorder = EnvironmentChangeRecorder(store: store, history: history)
        let first = timelineSnapshot(nodeVersion: "24.1.0", phpVersion: "8.4.1", at: start)
        await recorder.scanFinished(previous: nil, current: first)

        await history.add(CommandHistoryEntry(
            planKind: .update, providerID: .homebrew, commands: ["brew upgrade node"],
            targets: [OperationTarget(toolID: "node", installationID: "homebrew:node", packageName: "node", displayName: "Node.js", fromVersion: "24.1.0", toVersion: "24.2.0")],
            status: .running, startedAt: start.addingTimeInterval(30)
        ))
        let second = timelineSnapshot(nodeVersion: "24.2.0", phpVersion: "8.4.2", at: start.addingTimeInterval(60))
        await recorder.scanFinished(previous: first, current: second)
        // Nothing changed: no empty event.
        let third = timelineSnapshot(nodeVersion: "24.2.0", phpVersion: "8.4.2", at: start.addingTimeInterval(120))
        await recorder.scanFinished(previous: second, current: third)

        let events = await store.events(since: nil)
        #expect(events.count == 2)
        let latest = try #require(events.first)
        #expect(latest.previousCapturedAt == start)
        #expect(latest.changes.first { $0.toolID == "node" }?.origin.kind == .clistate)
        #expect(latest.changes.first { $0.toolID == "php" }?.origin.kind == .external)
    }

    @Test func scanCoordinatorComparesWithPersistedSnapshotWhenCacheWasNotLoaded() async throws {
        let store = JSONChangeEventStore(fileURL: nil, clock: { start })
        await store.append(EnvironmentChangeEvent(detectedAt: start, depth: .fast, isBaseline: true, changes: []))
        let repository = StaticRepository(stored: timelineSnapshot(nodeVersion: "24.1.0", at: start))
        let coordinator = ScanCoordinator(
            discovery: EmptyDiscovery(),
            providers: [],
            builder: FixedBuilder(snapshot: timelineSnapshot(nodeVersion: "24.2.0", at: start.addingTimeInterval(60))),
            repository: repository,
            recorder: EnvironmentChangeRecorder(store: store, history: FakeHistory())
        )
        _ = await coordinator.scan(depth: .fast)
        let events = await store.events(since: nil)
        #expect(events.first?.changes.map(\.kind) == [.versionChanged])
    }

    // MARK: End-of-life cache

    @Test func catalogCachesForSevenDaysAndOnlyFetchesWhenAllowed() async throws {
        let directory = temporaryFile("EndOfLife").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = CountingHTTP(body: Data(#"[{"cycle":"22","eol":"2027-04-30","releaseDate":"2024-04-24"}]"#.utf8))
        let clock = TestClock(start)
        let catalog = EndOfLifeCatalog(source: EndOfLifeSource(http: http), directory: directory, clock: { clock.now })

        #expect(await catalog.product("nodejs", allowNetwork: false) == nil)
        #expect(await http.count == 0)
        let fetched = try #require(await catalog.product("nodejs", allowNetwork: true))
        #expect(fetched.cycles.map(\.name) == ["22"])
        // v1 (404) and then the legacy endpoint.
        #expect(await http.count == 2)

        clock.advance(days: 6)
        _ = await catalog.product("nodejs", allowNetwork: true)
        #expect(await http.count == 2)

        // A new process reads the disk cache without the network, even when stale.
        clock.advance(days: 2)
        let reopened = EndOfLifeCatalog(source: EndOfLifeSource(http: http), directory: directory, clock: { clock.now })
        #expect(await reopened.product("nodejs", allowNetwork: false)?.fetchedAt == fetched.fetchedAt)
        #expect(await http.count == 2)
        _ = await reopened.product("nodejs", allowNetwork: true)
        #expect(await http.count == 4)
    }

    @Test func catalogFailuresAreSilentAndKeepStaleData() async throws {
        let http = CountingHTTP(body: Data(#"[{"cycle":"3.9","eol":"2025-10-31"}]"#.utf8))
        let clock = TestClock(start)
        let catalog = EndOfLifeCatalog(source: EndOfLifeSource(http: http), directory: nil, clock: { clock.now })
        let first = try #require(await catalog.product("python", allowNetwork: true))

        clock.advance(days: 8)
        await http.fail()
        #expect(await catalog.product("python", allowNetwork: true) == first)
        #expect(await catalog.lastErrors["python"] != nil)
        let attempts = await http.count
        // Doesn't hammer the network on every deep scan after a failure.
        #expect(await catalog.product("python", allowNetwork: true) == first)
        #expect(await http.count == attempts)
        #expect(await catalog.product("../python", allowNetwork: true) == nil)
    }
}

// MARK: - Fakes

private actor FakeHistory: CommandHistoryRepository {
    private var rows: [CommandHistoryEntry] = []
    func add(_ entry: CommandHistoryEntry) { rows.append(entry) }
    func entries(limit: Int) async throws -> [CommandHistoryEntry] { Array(rows.prefix(limit)) }
    func upsert(_ entry: CommandHistoryEntry) async throws { rows.append(entry) }
}

private actor StaticRepository: SnapshotRepository {
    var stored: EnvironmentSnapshot?
    init(stored: EnvironmentSnapshot?) { self.stored = stored }
    func load() async throws -> EnvironmentSnapshot? { stored }
    func save(_ snapshot: EnvironmentSnapshot) async throws { stored = snapshot }
}

private struct EmptyDiscovery: EnvironmentDiscovering {
    func discover() async throws -> DiscoveryResult {
        let shell = ShellEnvironment(shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh), path: [], variables: [:], source: .loginShell, capturedAt: start)
        return DiscoveryResult(session: ShellSession(environment: shell, execution: ExecutionEnvironment(variables: [:])), pathEntries: [], binaries: BinaryInventory())
    }
}

private struct FixedBuilder: SnapshotBuilding {
    let snapshot: EnvironmentSnapshot
    func buildSnapshot(discovery: DiscoveryResult, inventories: [ProviderInventory], failedProviders: [ProviderID: String], previous: EnvironmentSnapshot?, depth: ScanDepth, now: Date) async -> EnvironmentSnapshot {
        snapshot
    }
}

private actor CountingHTTP: HTTPFetching {
    private(set) var count = 0
    private let body: Data
    private var failing = false

    init(body: Data) { self.body = body }
    func fail() { failing = true }

    func get(_ url: URL, timeout: Duration) async throws -> HTTPResponse {
        count += 1
        if failing { throw URLError(.notConnectedToInternet) }
        // Serve only the legacy shape, so v1 is tried first and falls back.
        return url.path.contains("/v1/") ? HTTPResponse(statusCode: 404, body: Data()) : HTTPResponse(statusCode: 200, body: body)
    }
}

private func timelineSnapshot(nodeVersion: String, phpVersion: String? = nil, at date: Date) -> EnvironmentSnapshot {
    func tool(_ id: ToolID, _ name: String, _ version: String) -> Tool {
        let installation = ToolInstallation(
            id: .package(provider: .homebrew, name: id.rawValue),
            ownership: Ownership(provider: .homebrew, packageName: id.rawValue, confidence: .confirmed),
            version: ObservedValue(ToolVersion(version), source: .provider(.homebrew), confidence: .confirmed, observedAt: date),
            executables: [ExecutableRef(name: id.rawValue, path: "/opt/homebrew/bin/\(id.rawValue)", pathPriority: 1)],
            linkState: .active
        )
        return Tool(id: id, identity: ToolIdentity(name: id.rawValue, displayName: name, category: .runtime, registryID: id.rawValue), installations: [installation], activeInstallationID: installation.id, health: ToolHealthState(status: .healthy), lastScannedAt: date)
    }
    var tools = [tool("node", "Node.js", nodeVersion)]
    if let phpVersion { tools.append(tool("php", "PHP", phpVersion)) }
    return EnvironmentSnapshot(
        capturedAt: date,
        depth: .fast,
        shell: ShellEnvironment(shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh), path: [], variables: [:], source: .loginShell, capturedAt: date),
        pathEntries: [],
        brokenSymlinks: [],
        providers: [],
        tools: tools,
        services: [],
        issues: []
    )
}
