@testable import CLIStateApplication
import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing

// MARK: - Fakes

private let home = "/Users/tester"
private let cachePath = "\(home)/Library/Caches/php"
private let configPath = "\(home)/.config/php"

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

private struct Homebrew: ToolUninstallProvider {
    let id: ProviderID = .homebrew

    func availability(context: ProviderContext) async -> ProviderAvailability {
        ProviderAvailability(providerID: .homebrew, isAvailable: true, executable: "/opt/homebrew/bin/brew")
    }

    func scan(context: ProviderContext, depth: ScanDepth) async throws -> ProviderInventory {
        let php = ProviderTool(providerID: .homebrew, packageName: "php", kind: .formula, installedVersions: ["8.5.7"], activeVersion: "8.5.7")
        return ProviderInventory(providerID: .homebrew, availability: await availability(context: context), tools: [php], depth: depth, scannedAt: context.now)
    }

    func uninstallPlan(for tool: ProviderTool, context: ProviderContext) throws -> OperationPlan {
        OperationPlan(kind: .uninstall, providerID: .homebrew, targets: [], commands: [Command(executable: "/opt/homebrew/bin/brew", arguments: ["uninstall", tool.packageName])], requiresNetwork: false)
    }
}

private struct Builder: SnapshotBuilding {
    func buildSnapshot(discovery: DiscoveryResult, inventories: [ProviderInventory], failedProviders: [ProviderID: String], previous: EnvironmentSnapshot?, depth: ScanDepth, now: Date) async -> EnvironmentSnapshot {
        let installation = ToolInstallation(
            id: "homebrew:php",
            ownership: Ownership(provider: .homebrew, packageName: "php", confidence: .confirmed),
            version: ObservedValue(ToolVersion("8.5.7"), source: .provider(.homebrew), confidence: .confirmed, observedAt: now),
            executables: [ExecutableRef(name: "php", path: "/opt/homebrew/bin/php")],
            installPrefix: "/opt/homebrew/Cellar/php/8.5.7",
            linkState: .active,
            capabilities: ToolCapabilities(canUninstall: true)
        )
        let php = Tool(id: "php", identity: ToolIdentity(name: "php", displayName: "PHP", category: .runtime), installations: [installation], activeInstallationID: installation.id, health: ToolHealthState(status: .healthy), lastScannedAt: now)
        return EnvironmentSnapshot(capturedAt: now, depth: depth, shell: discovery.session.environment, pathEntries: [], brokenSymlinks: [], providers: [], tools: [php], services: [], issues: [])
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

private final class Trash: Trashing, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var moved: [String] { lock.withLock { paths } }
    func moveToTrash(path: String) throws { lock.withLock { paths.append(path) } }
}

/// Scanner whose findings a test can change between prepare and execute.
private final class Leftovers: LeftoverScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ToolID: [LeftoverItem]]

    init(_ items: [ToolID: [LeftoverItem]]) { self.items = items }

    func set(_ tool: ToolID, _ found: [LeftoverItem]) { lock.withLock { items[tool] = found } }

    func leftovers(for tool: ToolID, in snapshot: EnvironmentSnapshot) -> [LeftoverItem] {
        lock.withLock { items[tool] ?? [] }
    }
}

private let phpLeftovers = [
    LeftoverItem(path: cachePath, kind: .cache, origin: .exactName, sizeBytes: 2_000),
    LeftoverItem(path: configPath, kind: .config, origin: .exactName, sizeBytes: 40),
]

private func makeCoordinator(scanner: Leftovers?, runner: StubCommandRunner = StubCommandRunner(), trash: Trash = Trash()) async -> OperationCoordinator {
    let scan = ScanCoordinator(discovery: Discovery(), providers: [Homebrew()], builder: Builder(), repository: Snapshots())
    await scan.scan(depth: .fast)
    let fs = InMemoryFileSystem(home: home)
    fs.addExecutable("/opt/homebrew/bin/brew")
    fs.addExecutable("/opt/homebrew/bin/php")
    fs.addDirectory("/opt/homebrew/Cellar/php/8.5.7")
    return OperationCoordinator(scan: scan, runner: runner, locks: NoLocks(), trash: trash, history: History(), fileSystem: fs, leftoverScanner: scanner)
}

private func runToEnd(_ operations: OperationCoordinator, _ prepared: PreparedOperation) async -> OperationOutcome? {
    var outcome: OperationOutcome?
    for await progress in await operations.execute(prepared) {
        if case let .finished(result) = progress { outcome = result }
    }
    return outcome
}

// MARK: - Tests

@Suite("Leftover operations")
struct LeftoverOperationTests {
    @Test func exposesScannerResultsForTheUI() async {
        let operations = await makeCoordinator(scanner: Leftovers(["php": phpLeftovers]))
        #expect(await operations.leftovers(for: "php") == phpLeftovers)
        #expect(await operations.leftovers(for: "node").isEmpty)
        #expect(await makeCoordinator(scanner: nil).leftovers(for: "php").isEmpty)
    }

    @Test func uninstallRunsTheProviderFirstThenMovesLeftoversToTheTrash() async throws {
        let runner = StubCommandRunner()
        runner.stub("brew", ["uninstall", "php"], stdout: "Uninstalling /opt/homebrew/Cellar/php/8.5.7...\n")
        let trash = Trash()
        let operations = await makeCoordinator(scanner: Leftovers(["php": phpLeftovers]), runner: runner, trash: trash)

        let prepared = try await operations.prepare(.uninstall("homebrew:php", leftovers: [configPath, cachePath]))
        #expect(prepared.plan.kind == .uninstall)
        #expect(prepared.plan.steps == [
            .command(Command(executable: "/opt/homebrew/bin/brew", arguments: ["uninstall", "php"])),
            .moveToTrash(path: configPath),
            .moveToTrash(path: cachePath),
        ])
        let userData = try #require(prepared.checks.first { $0.kind == .userData })
        #expect(userData.outcome == .warning && userData.detail == configPath)
        #expect(!prepared.isBlocked)

        _ = await runToEnd(operations, prepared)
        #expect(runner.invocations.map(\.command.arguments) == [["uninstall", "php"]])
        #expect(trash.moved == [configPath, cachePath])
    }

    @Test func plainUninstallIsUnchanged() async throws {
        let operations = await makeCoordinator(scanner: Leftovers(["php": phpLeftovers]))
        let prepared = try await operations.prepare(.uninstall("homebrew:php"))
        #expect(prepared.plan.steps.count == 1)
        #expect(!prepared.checks.contains { $0.kind == .userData })
    }

    @Test func failedUninstallKeepsLeftovers() async throws {
        let runner = StubCommandRunner()
        runner.stub("brew", ["uninstall", "php"], stderr: "Error: Refusing to uninstall", exitCode: 1)
        let trash = Trash()
        let operations = await makeCoordinator(scanner: Leftovers(["php": phpLeftovers]), runner: runner, trash: trash)
        let prepared = try await operations.prepare(.uninstall("homebrew:php", leftovers: [cachePath]))
        let outcome = await runToEnd(operations, prepared)
        #expect(outcome?.status == .failed)
        #expect(trash.moved.isEmpty)
    }

    @Test func rejectsPathsTheScannerDidNotReturn() async throws {
        let operations = await makeCoordinator(scanner: Leftovers(["php": phpLeftovers]))
        await #expect(throws: OperationError.notPermitted("\(home)/.zshrc")) {
            try await operations.prepare(.uninstall("homebrew:php", leftovers: [cachePath, "\(home)/.zshrc"]))
        }
        await #expect(throws: OperationError.notPermitted(home)) {
            try await operations.prepare(.cleanLeftovers("php", paths: [home]))
        }
        // Another tool's leftovers are not this tool's.
        await #expect(throws: OperationError.notPermitted(cachePath)) {
            try await operations.prepare(.cleanLeftovers("node", paths: [cachePath]))
        }
        await #expect(throws: OperationError.notPermitted("")) {
            try await operations.prepare(.cleanLeftovers("php", paths: []))
        }
        await #expect(throws: OperationError.unsupported(.standalone)) {
            try await makeCoordinator(scanner: nil).prepare(.cleanLeftovers("php", paths: [cachePath]))
        }
    }

    @Test func rescansAtPrepareTime() async throws {
        let scanner = Leftovers(["php": phpLeftovers])
        let operations = await makeCoordinator(scanner: scanner)
        #expect(await operations.leftovers(for: "php").count == 2)
        scanner.set("php", [phpLeftovers[1]])
        await #expect(throws: OperationError.notPermitted(cachePath)) {
            try await operations.prepare(.cleanLeftovers("php", paths: [cachePath]))
        }
    }

    @Test func cleanLeftoversMovesOnlyToTheTrash() async throws {
        let runner = StubCommandRunner()
        let trash = Trash()
        let operations = await makeCoordinator(scanner: Leftovers(["php": phpLeftovers]), runner: runner, trash: trash)
        let prepared = try await operations.prepare(.cleanLeftovers("php", paths: [cachePath, cachePath]))
        #expect(prepared.plan.kind == .cleanup(.leftovers))
        #expect(prepared.plan.providerID == .standalone)
        #expect(prepared.plan.mutationScope == "trash")
        #expect(prepared.plan.steps == [.moveToTrash(path: cachePath)])
        #expect(prepared.plan.commands.isEmpty)
        #expect(prepared.plan.targets.first?.toolID == "php")
        #expect(prepared.plan.targets.first?.displayName == "PHP")
        #expect(prepared.checks.first { $0.kind == .userData }?.outcome == .passed)

        let outcome = await runToEnd(operations, prepared)
        #expect(outcome?.status == .succeeded)
        #expect(trash.moved == [cachePath])
        #expect(runner.invocations.isEmpty)
    }

    @Test func executeRefusesTrashStepsThatPrepareWouldNotAllow() async throws {
        let scanner = Leftovers(["php": phpLeftovers])
        let trash = Trash()
        let operations = await makeCoordinator(scanner: scanner, trash: trash)

        let forged = PreparedOperation(
            plan: OperationPlan(kind: .cleanup(.leftovers), providerID: .standalone, targets: [OperationTarget(toolID: "php", packageName: "php", displayName: "PHP")],
                                steps: [.moveToTrash(path: cachePath), .moveToTrash(path: "\(home)/.zshrc")], requiresNetwork: false, mutationScope: "trash"),
            checks: []
        )
        let outcome = await runToEnd(operations, forged)
        #expect(outcome?.failure?.reason == .preflightBlocked)
        #expect(trash.moved.isEmpty, "nothing runs when any step is refused")

        // The scanner runs again at execute time: an item that disappeared since prepare is refused.
        let prepared = try await operations.prepare(.cleanLeftovers("php", paths: [cachePath]))
        scanner.set("php", [])
        #expect(await runToEnd(operations, prepared)?.failure?.reason == .preflightBlocked)
        #expect(trash.moved.isEmpty)
    }

    @Test func trashablePathsIncludeOnlyScannedLeftovers() async throws {
        let builder = Builder()
        let snapshot = await builder.buildSnapshot(discovery: try await Discovery().discover(), inventories: [], failedProviders: [:], previous: nil, depth: .fast, now: Date())
        let paths = OperationCoordinator.trashablePaths(in: snapshot, leftovers: phpLeftovers)
        #expect(paths == [cachePath, configPath])
        #expect(OperationCoordinator.trashablePaths(in: snapshot).isEmpty)
    }
}
