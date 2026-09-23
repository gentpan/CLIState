@testable import CLIStateApplication
import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing

// MARK: - Fakes

/// Installed versions the builder reports, changed by a test to simulate the upgrade.
private final class Versions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    init(_ values: [String: String]) { self.values = values }
    subscript(name: String) -> String {
        get { lock.withLock { values[name] ?? "0" } }
        set { lock.withLock { values[name] = newValue } }
    }
}

private struct Discovery: EnvironmentDiscovering {
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

/// `brew upgrade php` whose dry run says composer (which depends on php) is upgraded too.
private struct Homebrew: ToolUpdateProvider, OperationPreflightProvider {
    let id: ProviderID = .homebrew
    let versions: Versions

    func availability(context: ProviderContext) async -> ProviderAvailability {
        ProviderAvailability(providerID: .homebrew, isAvailable: true, executable: "/opt/homebrew/bin/brew")
    }

    func scan(context: ProviderContext, depth: ScanDepth) async throws -> ProviderInventory {
        let tools = ["php", "composer"].map { name in
            ProviderTool(providerID: .homebrew, packageName: name, kind: .formula, installedVersions: [versions[name]], activeVersion: versions[name])
        }
        return ProviderInventory(providerID: .homebrew, availability: await availability(context: context), tools: tools, depth: depth, scannedAt: context.now)
    }

    func updatePlan(for tools: [ProviderTool], context: ProviderContext) throws -> OperationPlan {
        OperationPlan(kind: .update, providerID: .homebrew, targets: [], commands: [Command(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade"] + tools.map(\.packageName))], requiresNetwork: true)
    }

    func preflight(for plan: OperationPlan, context: ProviderContext) async -> [PreflightCheck] {
        [PreflightCheck(kind: .dryRun, outcome: .warning, items: [
            PreflightItem(name: "icu4c@77", change: .upgrade, fromVersion: "77.1", toVersion: "77.2"),
            PreflightItem(name: "composer", change: .upgradeDependent, fromVersion: "2.9.8", toVersion: "2.10.3"),
        ])]
    }
}

private struct Builder: SnapshotBuilding {
    let versions: Versions

    func buildSnapshot(discovery: DiscoveryResult, inventories: [ProviderInventory], failedProviders: [ProviderID: String], previous: EnvironmentSnapshot?, depth: ScanDepth, now: Date) async -> EnvironmentSnapshot {
        let latest = ["php": "8.5.10", "composer": "2.10.3"]
        let tools = ["php", "composer"].map { name in
            let installation = ToolInstallation(
                id: .package(provider: .homebrew, name: name),
                ownership: Ownership(provider: .homebrew, packageName: name, confidence: .confirmed),
                version: ObservedValue(ToolVersion(versions[name]), source: .provider(.homebrew), confidence: .confirmed, observedAt: now),
                latest: ObservedValue(ToolVersion(latest[name] ?? ""), source: .provider(.homebrew), confidence: .confirmed, observedAt: now),
                executables: [ExecutableRef(name: name, path: "/opt/homebrew/bin/\(name)")],
                linkState: .active,
                capabilities: ToolCapabilities(canUpdate: true, canUninstall: true)
            )
            return Tool(id: ToolID(name), identity: ToolIdentity(name: name, displayName: name, category: .developerTool), installations: [installation], activeInstallationID: installation.id, health: ToolHealthState(status: .updateAvailable), lastScannedAt: now)
        }
        return EnvironmentSnapshot(capturedAt: now, depth: depth, shell: discovery.session.environment, pathEntries: [], brokenSymlinks: [], providers: [], tools: tools, services: [], issues: [])
    }
}

private actor Snapshots: SnapshotRepository {
    var stored: EnvironmentSnapshot?
    func load() async throws -> EnvironmentSnapshot? { stored }
    func save(_ snapshot: EnvironmentSnapshot) async throws { stored = snapshot }
}

private actor History: CommandHistoryRepository {
    var rows: [UUID: CommandHistoryEntry] = [:]
    func entries(limit: Int) async throws -> [CommandHistoryEntry] { Array(rows.values.prefix(limit)) }
    func upsert(_ entry: CommandHistoryEntry) async throws { rows[entry.id] = entry }
}

private struct NoLocks: MutationLocking {
    func withMutationLock<T: Sendable>(scope: String, _ body: @Sendable () async throws -> T) async throws -> T { try await body() }
}

private struct NoTrash: Trashing {
    func moveToTrash(path: String) throws {}
}

// MARK: - Tests

@Suite("Dependent verification")
struct DependentVerificationTests {
    private func run(upgrade: [String: String]) async throws -> (OperationOutcome, CommandHistoryEntry) {
        let versions = Versions(["php": "8.5.7", "composer": "2.9.8"])
        let runner = StubCommandRunner()
        runner.stub("brew", ["upgrade", "php"], stdout: "==> Upgrading php\n")
        let history = History()
        let fileSystem = InMemoryFileSystem()
        fileSystem.addExecutable("/opt/homebrew/bin/brew")
        fileSystem.addExecutable("/opt/homebrew/bin/php")
        let scan = ScanCoordinator(discovery: Discovery(), providers: [Homebrew(versions: versions)], builder: Builder(versions: versions), repository: Snapshots())
        await scan.scan(depth: .fast)
        let operations = OperationCoordinator(scan: scan, runner: runner, locks: NoLocks(), trash: NoTrash(), history: history, fileSystem: fileSystem)

        let prepared = try await operations.prepare(.update(["homebrew:php"]))
        #expect(prepared.plan.targets.map(\.installationID) == ["homebrew:php"])
        for (name, version) in upgrade { versions[name] = version }

        var outcome: OperationOutcome?
        for await progress in await operations.execute(prepared) {
            if case let .finished(result) = progress { outcome = result }
        }
        let entry = try #require(await history.entries(limit: 1).first)
        return (try #require(outcome), entry)
    }

    @Test func dependentVersionsAreRecordedWithTheTarget() async throws {
        let (outcome, entry) = try await run(upgrade: ["php": "8.5.10", "composer": "2.10.3"])
        #expect(outcome.status == .succeeded)
        #expect(outcome.verifiedVersions == ["homebrew:php": "8.5.10", "homebrew:composer": "2.10.3"])
        #expect(entry.status == .succeeded)
        #expect(entry.verifiedVersions == ["homebrew:php": "8.5.10", "homebrew:composer": "2.10.3"])
        #expect(entry.targetVersions == ["homebrew:php": "8.5.10"])
        #expect(entry.dependents == [HistoryDependent(installationID: "homebrew:composer", name: "composer", version: "2.10.3")])
    }

    @Test func unchangedDependentDoesNotMakeTheEntryUnverified() async throws {
        let (outcome, entry) = try await run(upgrade: ["php": "8.5.10"])
        #expect(outcome.status == .succeeded)
        #expect(entry.status == .succeeded)
        #expect(entry.dependents.map(\.version) == ["2.9.8"])
    }

    @Test func unchangedTargetIsUnverifiedEvenIfDependentsChanged() async throws {
        let (outcome, entry) = try await run(upgrade: ["composer": "2.10.3"])
        #expect(outcome.status == .unverified)
        #expect(outcome.failure?.reason == .versionUnchanged)
        #expect(entry.status == .unverified)
        #expect(entry.targetVersions == ["homebrew:php": "8.5.7"], "History shows \"Still 8.5.7\" for php, not composer's version")
        #expect(entry.dependents.map(\.name) == ["composer"])
    }

    @Test func dependentsFromPreflightMatchTapNamesAndIgnoreOtherChanges() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func tool(_ name: String, provider: ProviderID = .homebrew, version: String) -> Tool {
            let installation = ToolInstallation(id: .package(provider: provider, name: name), ownership: Ownership(provider: provider, packageName: name, confidence: .confirmed),
                                                version: ObservedValue(ToolVersion(version), source: .provider(provider), confidence: .confirmed, observedAt: now), linkState: .active)
            return Tool(id: ToolID(name), identity: ToolIdentity(name: name, displayName: name, category: .developerTool), installations: [installation], health: ToolHealthState(status: .healthy), lastScannedAt: now)
        }
        let shell = ShellEnvironment(shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh), path: [], variables: [:], source: .loginShell, capturedAt: now)
        let snapshot = EnvironmentSnapshot(capturedAt: now, depth: .fast, shell: shell, pathEntries: [], brokenSymlinks: [], providers: [], tools: [
            tool("sqlc", version: "1.30.0"), tool("icu4c@77", version: "77.2"), tool("composer", provider: .npm, version: "9.9.9"),
        ], services: [], issues: [])
        let checks = [PreflightCheck(kind: .dryRun, outcome: .warning, items: [
            PreflightItem(name: "sqlc-dev/tap/sqlc", change: .upgradeDependent),
            PreflightItem(name: "icu4c@77", change: .upgrade),
            PreflightItem(name: "composer", change: .upgradeDependent),
        ])]
        let update = OperationPlan(kind: .update, providerID: .homebrew, targets: [], steps: [], requiresNetwork: true)
        #expect(OperationCoordinator.dependentVersions(checks: checks, plan: update, in: snapshot) == ["homebrew:sqlc": "1.30.0"])

        var uninstall = update
        uninstall.kind = .uninstall
        #expect(OperationCoordinator.dependentVersions(checks: checks, plan: uninstall, in: snapshot).isEmpty)
    }
}
