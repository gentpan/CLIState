@testable import CLIStateApplication
import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing

// MARK: - Fakes

private final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var current: Date { lock.withLock { value } }
    func advance(by seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private struct FakeDiscovery: EnvironmentDiscovering {
    func discover() async throws -> DiscoveryResult {
        let shell = ShellEnvironment(shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh), path: ["/opt/homebrew/bin"], variables: [:], source: .loginShell, capturedAt: Date(timeIntervalSince1970: 0))
        let brew = BinaryCandidate(name: "brew", path: "/opt/homebrew/bin/brew", pathPriority: 1, isSymlink: false, resolvedPath: "/opt/homebrew/bin/brew")
        return DiscoveryResult(
            session: ShellSession(environment: shell, execution: ExecutionEnvironment(variables: ["PATH": "/opt/homebrew/bin"])),
            pathEntries: [],
            binaries: BinaryInventory(groups: ["brew": BinaryGroup(executableName: "brew", candidates: [brew])])
        )
    }
}

private struct FakeHomebrew: ToolUpdateProvider, ToolUninstallProvider {
    let id: ProviderID = .homebrew
    let fails: Bool

    func availability(context: ProviderContext) async -> ProviderAvailability {
        ProviderAvailability(providerID: .homebrew, isAvailable: true, executable: "/opt/homebrew/bin/brew")
    }

    func scan(context: ProviderContext, depth: ScanDepth) async throws -> ProviderInventory {
        if fails { throw ProviderError.parsingFailed(.homebrew, what: "info") }
        let php = ProviderTool(providerID: .homebrew, packageName: "php", kind: .formula, installedVersions: ["8.5.7"], activeVersion: "8.5.7", latestVersion: "8.5.10")
        return ProviderInventory(providerID: .homebrew, availability: await availability(context: context), tools: [php], depth: depth, scannedAt: context.now)
    }

    func updatePlan(for tools: [ProviderTool], context: ProviderContext) throws -> OperationPlan {
        OperationPlan(kind: .update, providerID: .homebrew, targets: [], commands: [Command(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade"] + tools.map(\.packageName), environmentOverrides: ["HOMEBREW_NO_AUTO_UPDATE": "1"])], requiresNetwork: true)
    }

    func uninstallPlan(for tool: ProviderTool, context: ProviderContext) throws -> OperationPlan {
        OperationPlan(kind: .uninstall, providerID: .homebrew, targets: [], commands: [Command(executable: "/opt/homebrew/bin/brew", arguments: ["uninstall", tool.packageName])], requiresNetwork: false)
    }
}

/// Builds a one-tool snapshot whose PHP version comes from a mutable box, so a
/// test can simulate "the upgrade worked" before the verifying rescan.
private final class VersionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    init(_ value: String) { self.value = value }
    var current: String {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private struct FakeBuilder: SnapshotBuilding {
    let version: VersionBox
    let confidence: AttributionConfidence
    var cleanupCandidates: [CleanupCandidate] = []

    func buildSnapshot(discovery: DiscoveryResult, inventories: [ProviderInventory], failedProviders: [ProviderID: String], previous: EnvironmentSnapshot?, depth: ScanDepth, now: Date) async -> EnvironmentSnapshot {
        let installation = ToolInstallation(
            id: "homebrew:php",
            ownership: Ownership(provider: .homebrew, packageName: "php", confidence: confidence),
            version: ObservedValue(ToolVersion(version.current), source: .provider(.homebrew), confidence: .confirmed, observedAt: now),
            latest: ObservedValue(ToolVersion("8.5.10"), source: .provider(.homebrew), confidence: .confirmed, observedAt: now),
            executables: [ExecutableRef(name: "php", path: "/opt/homebrew/bin/php")],
            installPrefix: "/opt/homebrew/Cellar/php/\(version.current)",
            linkState: .active,
            capabilities: ToolCapabilities(canUpdate: true, canUninstall: true)
        )
        let php = Tool(id: "php", identity: ToolIdentity(name: "php", displayName: "PHP", category: .runtime), installations: [installation], activeInstallationID: installation.id, health: ToolHealthState(status: .updateAvailable), lastScannedAt: now)
        let issues = failedProviders.keys.map { HealthIssue(type: .providerScanFailed, severity: .warning, subject: $0.rawValue) }
        var snapshot = EnvironmentSnapshot(capturedAt: now, depth: depth, shell: discovery.session.environment, pathEntries: [], brokenSymlinks: [BrokenSymlink(path: "/opt/homebrew/bin/codexbar", destination: "../Caskroom/codexbar", pathPriority: 1)], providers: [], tools: [php], services: [], issues: issues)
        snapshot.cleanupCandidates = cleanupCandidates
        return snapshot
    }
}

private actor InMemorySnapshots: SnapshotRepository {
    var stored: EnvironmentSnapshot?
    func load() async throws -> EnvironmentSnapshot? { stored }
    func save(_ snapshot: EnvironmentSnapshot) async throws { stored = snapshot }
}

private actor InMemoryHistory: CommandHistoryRepository {
    var rows: [UUID: CommandHistoryEntry] = [:]
    func entries(limit: Int) async throws -> [CommandHistoryEntry] { Array(rows.values.sorted { $0.startedAt > $1.startedAt }.prefix(limit)) }
    func upsert(_ entry: CommandHistoryEntry) async throws { rows[entry.id] = entry }
}

private struct SerialLocks: MutationLocking {
    func withMutationLock<T: Sendable>(scope: String, _ body: @Sendable () async throws -> T) async throws -> T { try await body() }
}

private final class RecordingTrash: Trashing, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var moved: [String] { lock.withLock { paths } }
    func moveToTrash(path: String) throws { lock.withLock { paths.append(path) } }
}

private func makeFileSystem() -> InMemoryFileSystem {
    let fs = InMemoryFileSystem()
    fs.addExecutable("/opt/homebrew/bin/brew")
    fs.addExecutable("/opt/homebrew/bin/php")
    fs.addDirectory("/opt/homebrew/Cellar/php/8.5.7")
    return fs
}

// MARK: - Tests

@Suite("ScanCoordinator")
struct ScanCoordinatorTests {
    @Test func providerFailureDoesNotFailTheScan() async throws {
        let repository = InMemorySnapshots()
        let coordinator = ScanCoordinator(discovery: FakeDiscovery(), providers: [FakeHomebrew(fails: true)], builder: FakeBuilder(version: VersionBox("8.5.7"), confidence: .confirmed), repository: repository)
        let snapshot = try #require(await coordinator.scan(depth: .fast))
        #expect(snapshot.issues.map(\.type) == [.providerScanFailed])
        #expect(await repository.stored?.id == snapshot.id)
    }

    @Test func loadsCachedSnapshotBeforeScanning() async throws {
        let repository = InMemorySnapshots()
        let first = ScanCoordinator(discovery: FakeDiscovery(), providers: [], builder: FakeBuilder(version: VersionBox("8.5.7"), confidence: .confirmed), repository: repository)
        let scanned = try #require(await first.scan(depth: .fast))
        let second = ScanCoordinator(discovery: FakeDiscovery(), providers: [], builder: FakeBuilder(version: VersionBox("8.5.7"), confidence: .confirmed), repository: repository)
        #expect(await second.loadCached()?.id == scanned.id)
    }
}

@Suite("OperationCoordinator")
struct OperationCoordinatorTests {
    private func makeCoordinator(version: VersionBox, confidence: AttributionConfidence = .confirmed, runner: StubCommandRunner, history: InMemoryHistory = InMemoryHistory(), trash: RecordingTrash = RecordingTrash()) async -> (ScanCoordinator, OperationCoordinator) {
        let scan = ScanCoordinator(discovery: FakeDiscovery(), providers: [FakeHomebrew(fails: false)], builder: FakeBuilder(version: version, confidence: confidence), repository: InMemorySnapshots())
        await scan.scan(depth: .fast)
        let operations = OperationCoordinator(scan: scan, runner: runner, locks: SerialLocks(), trash: trash, history: history, fileSystem: makeFileSystem())
        return (scan, operations)
    }

    @Test func refusesToPrepareBeforeAnyScan() async {
        let scan = ScanCoordinator(discovery: FakeDiscovery(), providers: [], builder: FakeBuilder(version: VersionBox("1"), confidence: .confirmed), repository: InMemorySnapshots())
        let operations = OperationCoordinator(scan: scan, runner: StubCommandRunner(), locks: SerialLocks(), trash: RecordingTrash(), history: InMemoryHistory(), fileSystem: makeFileSystem())
        await #expect(throws: OperationError.scanRequired) { try await operations.prepare(.update(["homebrew:php"])) }
    }

    @Test func probableOwnershipBlocksUpdate() async throws {
        let (_, operations) = await makeCoordinator(version: VersionBox("8.5.7"), confidence: .probable, runner: StubCommandRunner())
        let prepared = try await operations.prepare(.update(["homebrew:php"]))
        #expect(prepared.isBlocked)
        #expect(prepared.checks.contains { $0.kind == .ownershipConfirmed && $0.outcome == .failed })
    }

    @Test func successfulUpdateIsVerifiedByRescanAndRecorded() async throws {
        let version = VersionBox("8.5.7")
        let runner = StubCommandRunner()
        runner.stub("brew", ["upgrade", "php"], stdout: "==> Upgrading php\n8.5.7 -> 8.5.10\n")
        let history = InMemoryHistory()
        let (_, operations) = await makeCoordinator(version: version, runner: runner, history: history)

        let prepared = try await operations.prepare(.update(["homebrew:php"]))
        #expect(!prepared.isBlocked)
        #expect(prepared.plan.targets.first?.fromVersion == "8.5.7")
        #expect(prepared.plan.targets.first?.toVersion == "8.5.10")

        version.current = "8.5.10"
        var lines: [String] = []
        var outcome: OperationOutcome?
        for await progress in await operations.execute(prepared) {
            switch progress {
            case let .output(line): lines.append(line.text)
            case let .finished(result): outcome = result
            default: break
            }
        }
        let result = try #require(outcome)
        #expect(result.status == .succeeded)
        #expect(result.verifiedVersions["homebrew:php"] == "8.5.10")
        #expect(lines.contains("8.5.7 -> 8.5.10"))
        #expect(runner.invocations.first?.command.environmentOverrides["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        let recorded = try #require(await history.entries(limit: 1).first)
        #expect(recorded.status == .succeeded)
        #expect(recorded.commands == ["brew upgrade php"])
    }

    @Test func exitZeroWithUnchangedVersionIsUnverified() async throws {
        let runner = StubCommandRunner()
        runner.stub("brew", ["upgrade", "php"], stdout: "Warning: php 8.5.7 already installed\n")
        let (_, operations) = await makeCoordinator(version: VersionBox("8.5.7"), runner: runner)
        let prepared = try await operations.prepare(.update(["homebrew:php"]))
        var outcome: OperationOutcome?
        for await progress in await operations.execute(prepared) {
            if case let .finished(result) = progress { outcome = result }
        }
        #expect(outcome?.status == .unverified)
        #expect(outcome?.failure?.reason == .versionUnchanged)
    }

    @Test func failedCommandIsClassified() async throws {
        let runner = StubCommandRunner()
        runner.stub("brew", ["upgrade", "php"], stderr: "Error: Permission denied @ dir_s_mkdir - /opt/homebrew/Cellar", exitCode: 1)
        let (_, operations) = await makeCoordinator(version: VersionBox("8.5.7"), runner: runner)
        let prepared = try await operations.prepare(.update(["homebrew:php"]))
        var outcome: OperationOutcome?
        for await progress in await operations.execute(prepared) {
            if case let .finished(result) = progress { outcome = result }
        }
        #expect(outcome?.status == .failed)
        #expect(outcome?.failure?.reason == .permissionDenied)
        #expect(outcome?.failure?.exitCode == 1)
    }

    @Test func moveToTrashOnlyAcceptsKnownPaths() async throws {
        let trash = RecordingTrash()
        let (_, operations) = await makeCoordinator(version: VersionBox("8.5.7"), runner: StubCommandRunner(), trash: trash)
        await #expect(throws: OperationError.notPermitted("/Users/tester/.zshrc")) {
            try await operations.prepare(.moveToTrash(path: "/Users/tester/.zshrc"))
        }
        let prepared = try await operations.prepare(.moveToTrash(path: "/opt/homebrew/bin/codexbar"))
        for await _ in await operations.execute(prepared) {}
        #expect(trash.moved == ["/opt/homebrew/bin/codexbar"])
    }
}

@Suite("AutoUpdatePlanner")
struct AutoUpdatePlannerTests {
    @Test func notifyIsDefaultAndAutomaticNeedsOptIn() async throws {
        let builder = FakeBuilder(version: VersionBox("8.5.7"), confidence: .confirmed)
        let snapshot = await builder.buildSnapshot(discovery: try await FakeDiscovery().discover(), inventories: [], failedProviders: [:], previous: nil, depth: .deep, now: Date())
        let planner = AutoUpdatePlanner()

        #expect(planner.decide(snapshot: snapshot, preferences: UpdatePreferences()).notify == ["homebrew:php"])
        #expect(planner.decide(snapshot: snapshot, preferences: UpdatePreferences(toolPolicies: ["php": .automatic])).automatic == ["homebrew:php"])
        #expect(planner.decide(snapshot: snapshot, preferences: UpdatePreferences(defaultPolicy: .off)) == .init(automatic: [], notify: [], needsReview: []))
        #expect(planner.decide(snapshot: snapshot, preferences: UpdatePreferences(skippedVersions: ["homebrew:php": "8.5.10"])).notify.isEmpty)
    }
}

@Suite("Persistence")
struct PersistenceTests {
    @Test func snapshotRoundTripsAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONSnapshotRepository(fileURL: directory.appendingPathComponent("snapshot.json"))
        #expect(try await repository.load() == nil)

        let builder = FakeBuilder(version: VersionBox("8.5.7"), confidence: .confirmed)
        let snapshot = await builder.buildSnapshot(discovery: try await FakeDiscovery().discover(), inventories: [], failedProviders: [:], previous: nil, depth: .fast, now: Date(timeIntervalSince1970: 1_800_000_000))
        try await repository.save(snapshot)
        #expect(try await repository.load() == snapshot)
    }

    @Test func corruptSnapshotIsQuarantined() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        try Data("{not json".utf8).write(to: file)
        #expect(try await JSONSnapshotRepository(fileURL: file).load() == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.count == 1 && names[0].hasPrefix("snapshot.json.corrupt-"))
    }

    @Test func historyUpsertsAndMarksInterrupted() async throws {
        let repository = try SwiftDataHistoryRepository.make(inMemory: true)
        var entry = CommandHistoryEntry(planKind: .update, providerID: .homebrew, commands: ["brew upgrade php"], targets: [], status: .running, startedAt: Date())
        try await repository.upsert(entry)
        entry.status = .succeeded
        try await repository.upsert(entry)
        #expect(try await repository.entries(limit: 10).map(\.status) == [.succeeded])

        let orphan = CommandHistoryEntry(planKind: .cleanup(.providerCache), providerID: .npm, commands: ["npm cache clean --force"], targets: [], status: .running, startedAt: Date().addingTimeInterval(10))
        try await repository.upsert(orphan)
        try await repository.markInterruptedEntries()
        #expect(try await repository.entries(limit: 1).first?.status == .interrupted)
    }
}

@Suite("Diagnostics")
struct DiagnosticsTests {
    private let context = DiagnosticsExporter.Context(appVersion: "0.1.0", build: "1", osVersion: "Version 27.0", architecture: "arm64", homeDirectory: "/Users/peter", userName: "peter")

    private func snapshot() -> EnvironmentSnapshot {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let shell = ShellEnvironment(shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh), path: ["/Users/peter/.local/bin"], variables: ["HOME": "/Users/peter", "PATH": "/Users/peter/.local/bin"], source: .loginShell, capturedAt: now)
        let installation = ToolInstallation(
            id: .path("/Users/peter/.local/bin/node"),
            ownership: Ownership(provider: .standalone, confidence: .unknown, evidence: [.pathDirectory("/Users/peter/.local/bin")]),
            executables: [ExecutableRef(name: "node", path: "/Users/peter/.local/bin/node", pathPriority: 1)],
            linkState: .active
        )
        let peterParser = Tool(id: "npm.peter-parser", identity: ToolIdentity(name: "peter-parser", displayName: "peter-parser", category: .developerTool), installations: [], health: ToolHealthState(status: .healthy), lastScannedAt: now)
        let node = Tool(id: "node", identity: ToolIdentity(name: "node", displayName: "Node.js", category: .runtime), installations: [installation], activeInstallationID: installation.id, health: ToolHealthState(status: .healthy), lastScannedAt: now)
        return EnvironmentSnapshot(
            capturedAt: now, depth: .fast, shell: shell,
            pathEntries: [PATHEntry(priority: 1, rawValue: "/Users/peter/.local/bin", normalizedPath: "/Users/peter/.local/bin", status: .ok, source: .userLocal)],
            brokenSymlinks: [], providers: [], tools: [node, peterParser],
            services: [ToolService(id: "redis", name: "redis", providerID: .homebrew, status: .running, user: "peter")],
            issues: [HealthIssue(type: .missingPathEntry, severity: .warning, subject: "/Users/peter/old/bin", paths: ["/Users/peter/old/bin"])]
        )
    }

    @Test func bundleIsRedactedAndHasNoEnvironment() throws {
        let files = try DiagnosticsExporter(context: context).files(snapshot: snapshot(), history: [])
        #expect(Set(files.keys) == ["app-version.txt", "system.txt", "path.json", "providers.json", "health.json", "tools.json", "cleanup.json", "recent-operations.json"])
        let everything = files.values.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        #expect(!everything.contains("/Users/peter"))
        #expect(everything.contains("~/.local/bin/node"))
        #expect(everything.contains("peter-parser"), "package names containing the user name must survive")
        #expect(!everything.contains("\"variables\""), "no environment variables in the bundle")
    }

    @Test func redactsStandaloneUserName() {
        let exporter = DiagnosticsExporter(context: context)
        #expect(exporter.redact("user peter owns /Users/peter/x and peterson") == "user <user> owns ~/x and peterson")
    }
}

private struct FakeHomebrewWithRefresh: ToolUpdateProvider, MetadataRefreshProvider {
    let id: ProviderID = .homebrew
    func availability(context: ProviderContext) async -> ProviderAvailability {
        ProviderAvailability(providerID: .homebrew, isAvailable: true, executable: "/opt/homebrew/bin/brew")
    }
    func scan(context: ProviderContext, depth: ScanDepth) async throws -> ProviderInventory {
        try await FakeHomebrew(fails: false).scan(context: context, depth: depth)
    }
    func updatePlan(for tools: [ProviderTool], context: ProviderContext) throws -> OperationPlan {
        try FakeHomebrew(fails: false).updatePlan(for: tools, context: context)
    }
    func refreshMetadataPlan(context: ProviderContext) throws -> OperationPlan {
        OperationPlan(kind: .refreshMetadata, providerID: .homebrew, targets: [], commands: [Command(executable: "/opt/homebrew/bin/brew", arguments: ["update"])], requiresNetwork: true)
    }
}

private struct AlwaysOnPower: PowerSourceMonitoring {
    var isOnACPower: Bool { true }
}

@Suite("AutoUpdateRunner")
struct AutoUpdateRunnerTests {
    private func makeRunner(runner: StubCommandRunner, history: InMemoryHistory, clock: DateBox? = nil) -> AutoUpdateRunner {
        let now: @Sendable () -> Date = { clock?.current ?? Date() }
        let scan = ScanCoordinator(discovery: FakeDiscovery(), providers: [FakeHomebrewWithRefresh()], builder: FakeBuilder(version: VersionBox("8.5.7"), confidence: .confirmed), repository: InMemorySnapshots(), clock: now)
        let operations = OperationCoordinator(scan: scan, runner: runner, locks: SerialLocks(), trash: RecordingTrash(), history: history, fileSystem: makeFileSystem(), clock: now)
        return AutoUpdateRunner(scan: scan, operations: operations, power: AlwaysOnPower(), history: history, clock: now)
    }

    @Test func everyCheckRefreshesUnlessPackageInfoIsMinutesOld() async throws {
        let runner = StubCommandRunner()
        runner.stub("brew", ["update"], stdout: "Already up-to-date.\n")
        let history = InMemoryHistory()
        let clock = DateBox(Date(timeIntervalSince1970: 1_800_000_000))
        let auto = makeRunner(runner: runner, history: history, clock: clock)
        func updateCount() -> Int { runner.invocations.filter { $0.command.arguments == ["update"] }.count }

        #expect(await auto.run(preferences: UpdatePreferences()).metadataRefreshes.count == 1)
        clock.advance(by: 5 * 60)
        let second = await auto.run(preferences: UpdatePreferences())
        #expect(second.metadataRefreshes.isEmpty, "back-to-back checks don't run brew update twice")
        #expect(second.notify == ["homebrew:php"], "the check itself still runs")
        #expect(updateCount() == 1)

        clock.advance(by: 6 * 60)
        #expect(await auto.run(preferences: UpdatePreferences()).metadataRefreshes.count == 1)
        clock.advance(by: 3 * 3600)
        #expect(await auto.refreshStaleMetadata(trigger: .user).map(\.plan.trigger) == [.user])
        #expect(updateCount() == 3)
    }

    @Test func periodicChecksOnlyReportAutomaticUpdates() async throws {
        let runner = StubCommandRunner()
        runner.stub("brew", ["update"], stdout: "Already up-to-date.\n")
        let preferences = UpdatePreferences(defaultPolicy: .automatic, automaticScope: .all, requiresACPower: false)
        let report = await makeRunner(runner: runner, history: InMemoryHistory()).run(preferences: preferences, allowAutomaticInstalls: false)
        #expect(report.updated.isEmpty)
        #expect(report.notify == ["homebrew:php"])
        #expect(!runner.invocations.contains { $0.command.arguments.first == "upgrade" })
    }

    @Test func failedOrManualRefreshCountsOnlyWhenSucceeded() async throws {
        let history = InMemoryHistory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await history.upsert(CommandHistoryEntry(planKind: .refreshMetadata, trigger: .user, providerID: .homebrew, commands: ["brew update"], targets: [], status: .failed, startedAt: now.addingTimeInterval(-600), finishedAt: now.addingTimeInterval(-590)))
        let runner = StubCommandRunner()
        runner.stub("brew", ["update"], stdout: "Updated 1 tap.\n")
        let auto = makeRunner(runner: runner, history: history, clock: DateBox(now))
        #expect(await auto.run(preferences: UpdatePreferences()).metadataRefreshes.map(\.status) == [.succeeded], "a failed refresh doesn't count")

        let manual = InMemoryHistory()
        try await manual.upsert(CommandHistoryEntry(planKind: .refreshMetadata, trigger: .user, providerID: .homebrew, commands: ["brew update"], targets: [], status: .succeeded, startedAt: now.addingTimeInterval(-300), finishedAt: now.addingTimeInterval(-280)))
        let quiet = StubCommandRunner()
        #expect(await makeRunner(runner: quiet, history: manual, clock: DateBox(now)).run(preferences: UpdatePreferences()).metadataRefreshes.isEmpty, "Refresh Package Info a few minutes ago counts")
        #expect(!quiet.invocations.map(\.command.arguments).contains(["update"]))
    }

    @Test func refreshesHomebrewMetadataBeforeCheckingAndRecordsIt() async throws {
        let runner = StubCommandRunner()
        runner.stub("brew", ["update"], stdout: "Already up-to-date.\n")
        let history = InMemoryHistory()
        let report = await makeRunner(runner: runner, history: history).run(preferences: UpdatePreferences())

        #expect(report.metadataRefreshes.map(\.status) == [.succeeded])
        #expect(runner.invocations.map(\.command.arguments).contains(["update"]))
        #expect(report.notify == ["homebrew:php"])
        let recorded = try await history.entries(limit: 10)
        #expect(recorded.contains { $0.planKind == .refreshMetadata && $0.trigger == .automaticPolicy })
    }

    @Test func refreshCanBeTurnedOff() async throws {
        let runner = StubCommandRunner()
        let report = await makeRunner(runner: runner, history: InMemoryHistory()).run(preferences: UpdatePreferences(refreshMetadataBeforeCheck: false))
        #expect(report.metadataRefreshes.isEmpty)
        #expect(!runner.invocations.map(\.command.arguments).contains(["update"]))
    }

    @Test func oldPreferencesWithoutNewKeysStillDecode() throws {
        let legacy = Data(#"{"defaultPolicy":"automatic","providerPolicies":{},"toolPolicies":{"php":"off"},"automaticScope":"all","skippedVersions":{},"checkHour":9,"requiresACPower":false}"#.utf8)
        let decoded = try JSONDecoder().decode(UpdatePreferences.self, from: legacy)
        #expect(decoded.defaultPolicy == .automatic)
        #expect(decoded.toolPolicies["php"] == .off)
        #expect(decoded.refreshMetadataBeforeCheck)
        #expect(decoded.checkInterval == .every3Hours)
    }
}

private actor FailingRescanDiscovery: EnvironmentDiscovering {
    var calls = 0
    let cancellation: Bool
    init(cancellation: Bool) { self.cancellation = cancellation }
    func discover() async throws -> DiscoveryResult {
        calls += 1
        if calls > 1 {
            if cancellation { throw CancellationError() }
            throw CocoaError(.fileReadUnknown)
        }
        return try await FakeDiscovery().discover()
    }
}

@Suite("Verification scan failures")
struct VerificationScanFailureTests {
    @Test(arguments: [OperationKind.update, .selfUpdate, .install, .uninstall], [false, true])
    func missingRescanCannotVerifySuccess(kind: OperationKind, cancellation: Bool) async throws {
        let scan = ScanCoordinator(discovery: FailingRescanDiscovery(cancellation: cancellation), providers: [FakeHomebrew(fails: false)], builder: FakeBuilder(version: VersionBox("8.5.7"), confidence: .confirmed), repository: InMemorySnapshots())
        _ = try #require(await scan.scan(depth: .fast))
        let runner = StubCommandRunner()
        runner.stub("brew", ["operation"], stdout: "done")
        let history = InMemoryHistory()
        let operations = OperationCoordinator(scan: scan, runner: runner, locks: SerialLocks(), trash: RecordingTrash(), history: history, fileSystem: makeFileSystem())
        let plan = OperationPlan(kind: kind, providerID: .homebrew, targets: [OperationTarget(installationID: "homebrew:php", packageName: "php", displayName: "PHP", fromVersion: "8.5.7")], commands: [Command(executable: "/opt/homebrew/bin/brew", arguments: ["operation"])], requiresNetwork: false)
        var outcome: OperationOutcome?
        for await event in await operations.execute(PreparedOperation(plan: plan, checks: [])) {
            if case let .finished(value) = event { outcome = value }
        }
        #expect(outcome?.status == .unverified)
        #expect(outcome?.verifiedVersions.isEmpty == true)
        #expect(outcome?.failure == nil, "A failed scan does not prove the version stayed unchanged")
        #expect(try await history.entries(limit: 1).first?.status == .unverified)
    }
}

private actor ReviewLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private struct PausedCleanupProvider: CleanupProvider {
    let id: ProviderID = .homebrew
    let entered: ReviewLatch
    let resume: ReviewLatch
    func availability(context: ProviderContext) async -> ProviderAvailability {
        await FakeHomebrew(fails: false).availability(context: context)
    }
    func scan(context: ProviderContext, depth: ScanDepth) async throws -> ProviderInventory {
        try await FakeHomebrew(fails: false).scan(context: context, depth: depth)
    }
    func cleanupCandidates(context: ProviderContext) async throws -> [CleanupCandidate] {
        await entered.open()
        await resume.wait()
        return [CleanupCandidate(kind: .providerCache, providerID: .homebrew, risk: .low, paths: ["/old/cache"], plan: nil)]
    }
}

@Suite("Cleanup scan concurrency")
struct CleanupScanConcurrencyTests {
    @Test func previewPreservesProviderAttributedEngineSuggestions() async throws {
        let resume = ReviewLatch()
        await resume.open()
        let link = CleanupCandidate(kind: .brokenSymlink, providerID: .homebrew, risk: .low, paths: ["/opt/homebrew/bin/old"], plan: nil)
        let runtime = CleanupCandidate(kind: .unusedRuntime, providerID: .nvm, risk: .medium, paths: ["/home/test/.nvm/old"], plan: nil)
        let staleCache = CleanupCandidate(kind: .providerCache, providerID: .homebrew, risk: .low, paths: ["/stale/cache"], plan: nil)
        let scan = ScanCoordinator(discovery: FakeDiscovery(), providers: [PausedCleanupProvider(entered: ReviewLatch(), resume: resume)], builder: FakeBuilder(version: VersionBox("8.5.7"), confidence: .confirmed, cleanupCandidates: [link, runtime, staleCache]), repository: InMemorySnapshots())
        _ = try #require(await scan.scan(depth: .fast))
        let candidates = await scan.refreshCleanupCandidates()
        #expect(candidates.contains(link))
        #expect(candidates.contains(runtime))
        #expect(!candidates.contains(staleCache))
        #expect(candidates.contains { $0.paths == ["/old/cache"] })
    }

    @Test(.timeLimit(.minutes(1)))
    func oldCleanupDoesNotOverwriteNewSnapshot() async throws {
        let entered = ReviewLatch()
        let resume = ReviewLatch()
        let version = VersionBox("8.5.7")
        let repository = InMemorySnapshots()
        let scan = ScanCoordinator(discovery: FakeDiscovery(), providers: [PausedCleanupProvider(entered: entered, resume: resume)], builder: FakeBuilder(version: version, confidence: .confirmed), repository: repository)
        _ = try #require(await scan.scan(depth: .fast))
        let cleanup = Task { await scan.refreshCleanupCandidates() }
        await entered.wait()
        version.current = "8.5.10"
        let newer = await scan.scan(depth: .deep)
        await resume.open()
        let candidates = await cleanup.value
        let fresh = try #require(newer)
        #expect(candidates == fresh.cleanupCandidates)
        #expect(await scan.snapshot?.id == fresh.id)
        #expect(await repository.stored?.id == fresh.id)
        #expect(await scan.snapshot?.tools.first?.installations.first?.version?.value.rawValue == "8.5.10")
    }

    @Test func cleanupStillPublishesWithoutAnInterveningScan() async throws {
        let resume = ReviewLatch()
        await resume.open()
        let repository = InMemorySnapshots()
        let scan = ScanCoordinator(discovery: FakeDiscovery(), providers: [PausedCleanupProvider(entered: ReviewLatch(), resume: resume)], builder: FakeBuilder(version: VersionBox("8.5.7"), confidence: .confirmed), repository: repository)
        _ = try #require(await scan.scan(depth: .fast))
        #expect(await scan.refreshCleanupCandidates().first?.paths == ["/old/cache"])
        #expect(await repository.stored?.cleanupCandidates.first?.paths == ["/old/cache"])
    }
}

private final class MutablePower: PowerSourceMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var connected = false
    var isOnACPower: Bool { lock.withLock { connected } }
    func connect() { lock.withLock { connected = true } }
}

@Suite("Automatic pass retry eligibility")
struct AutomaticPassRetryTests {
    @Test func powerSkipLeavesDailyPassAvailableUntilConnected() async throws {
        let scan = ScanCoordinator(discovery: FakeDiscovery(), providers: [FakeHomebrew(fails: false)], builder: FakeBuilder(version: VersionBox("8.5.7"), confidence: .confirmed), repository: InMemorySnapshots())
        let runner = StubCommandRunner()
        runner.stub("brew", ["upgrade", "php"], stdout: "done")
        let operations = OperationCoordinator(scan: scan, runner: runner, locks: SerialLocks(), trash: RecordingTrash(), history: InMemoryHistory(), fileSystem: makeFileSystem())
        let power = MutablePower()
        let auto = AutoUpdateRunner(scan: scan, operations: operations, power: power)
        let preferences = UpdatePreferences(defaultPolicy: .automatic, requiresACPower: true, refreshMetadataBeforeCheck: false)
        let first = await auto.run(preferences: preferences)
        #expect(first.scanCompleted)
        #expect(first.skippedForPower)
        #expect(!first.didCompleteAutomaticPass)
        #expect(runner.invocations.isEmpty)
        power.connect()
        let second = await auto.run(preferences: preferences)
        #expect(second.didCompleteAutomaticPass)
        #expect(second.updated.count == 1)
        #expect(runner.invocations.count == 1)
    }

    @Test func failedScanLeavesDailyPassAvailable() async throws {
        let scan = ScanCoordinator(discovery: FailingRescanDiscovery(cancellation: false), providers: [], builder: FakeBuilder(version: VersionBox("8.5.7"), confidence: .confirmed), repository: InMemorySnapshots())
        _ = try #require(await scan.scan(depth: .fast))
        let operations = OperationCoordinator(scan: scan, runner: StubCommandRunner(), locks: SerialLocks(), trash: RecordingTrash(), history: InMemoryHistory(), fileSystem: makeFileSystem())
        let report = await AutoUpdateRunner(scan: scan, operations: operations).run(preferences: UpdatePreferences(refreshMetadataBeforeCheck: false))
        #expect(!report.scanCompleted)
        #expect(!report.didCompleteAutomaticPass)
    }
}
