@testable import CLIStateApplication
import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing

private struct EmptyDiscovery: EnvironmentDiscovering {
    func discover() async throws -> DiscoveryResult {
        let shell = ShellEnvironment(shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh), path: [], variables: [:], source: .loginShell, capturedAt: Date(timeIntervalSince1970: 0))
        return DiscoveryResult(session: ShellSession(environment: shell, execution: ExecutionEnvironment(variables: [:])), pathEntries: [], binaries: BinaryInventory())
    }
}

private struct EmptyBuilder: SnapshotBuilding {
    func buildSnapshot(discovery: DiscoveryResult, inventories: [ProviderInventory], failedProviders: [ProviderID: String], previous: EnvironmentSnapshot?, depth: ScanDepth, now: Date) async -> EnvironmentSnapshot {
        EnvironmentSnapshot(capturedAt: now, depth: depth, shell: discovery.session.environment, pathEntries: [], brokenSymlinks: [], providers: [], tools: [], services: [], issues: [])
    }
}

@Suite("Launch robustness")
struct LaunchRobustnessTests {
    private let stamp = Date(timeIntervalSince1970: 1_789_300_500)

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clistate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func undecodableSnapshotIsMovedAsideNeverOverwritten() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        let repository = JSONSnapshotRepository(fileURL: file, clock: { [stamp] in stamp })

        try Data("{not json".utf8).write(to: file)
        #expect(try await repository.load() == nil)
        try Data(#"{"schemaVersion":1,"tools":"wrong shape"}"#.utf8).write(to: file)
        #expect(try await repository.load() == nil)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["snapshot.json.corrupt-20260913T115500Z", "snapshot.json.corrupt-20260913T115500Z-2"])
        #expect(try Data(contentsOf: directory.appendingPathComponent(names[0])) == Data("{not json".utf8), "the first copy is kept as it was")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func snapshotFromAnotherSchemaIsMovedAside() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        let repository = JSONSnapshotRepository(fileURL: file, clock: { [stamp] in stamp })
        var snapshot = await EmptyBuilder().buildSnapshot(discovery: try await EmptyDiscovery().discover(), inventories: [], failedProviders: [:], previous: nil, depth: .fast, now: stamp)
        snapshot.schemaVersion = EnvironmentSnapshot.currentSchemaVersion + 1
        try await repository.save(snapshot)

        #expect(try await repository.load() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["snapshot.json.corrupt-20260913T115500Z"])
    }

    @Test func launchWithCorruptCacheStartsFromAFreshScan() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        try Data(#"{"schemaVersion":"#.utf8).write(to: file)
        let repository = JSONSnapshotRepository(fileURL: file, clock: { [stamp] in stamp })
        let coordinator = ScanCoordinator(discovery: EmptyDiscovery(), providers: [], builder: EmptyBuilder(), repository: repository)

        #expect(await coordinator.loadCached() == nil)
        #expect(LatestVersionFreshness.needsDeepCheck(await coordinator.snapshot, now: stamp))
        let scanned = try #require(await coordinator.scan(depth: .fast))
        #expect(try await repository.load()?.id == scanned.id)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("snapshot.json.corrupt-20260913T115500Z").path))
    }

    @Test func unreadablePreferencesKeepDefaultsWithoutOverwriting() throws {
        let suite = "clistate-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UpdatePreferencesStore(defaults: defaults)
        #expect(store.load().state == .missing)

        let garbage = Data("\u{0}not json".utf8)
        defaults.set(garbage, forKey: UpdatePreferencesStore.defaultsKey)
        let loaded = store.load()
        #expect(loaded.state == .unreadable)
        #expect(loaded.preferences == UpdatePreferences())
        #expect(defaults.data(forKey: UpdatePreferencesStore.defaultsKey) == garbage, "loading never writes")

        var changed = loaded.preferences
        changed.checkHour = 7
        try store.save(changed)
        #expect(store.load() == (changed, .loaded))
    }

    @Test func oneUnknownPreferenceValueDoesNotResetTheOthers() throws {
        let future = Data(#"{"defaultPolicy":"weekly","toolPolicies":{"php":"off"},"checkHour":6,"requiresACPower":"sometimes"}"#.utf8)
        let decoded = try JSONDecoder().decode(UpdatePreferences.self, from: future)
        #expect(decoded.defaultPolicy == UpdatePreferences().defaultPolicy)
        #expect(decoded.toolPolicies["php"] == .off)
        #expect(decoded.checkHour == 6)
        #expect(decoded.requiresACPower == UpdatePreferences().requiresACPower)
    }
}
