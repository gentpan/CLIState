@testable import CLIStateApplication
import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing

// MARK: - Fakes

private struct RestoreDiscovery: EnvironmentDiscovering {
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

/// Homebrew formulae installed "so far"; the test fills it in to simulate a working install.
private final class InstalledBox: @unchecked Sendable {
    private let lock = NSLock()
    private var packages: [String: String] = [:]
    var current: [String: String] {
        get { lock.withLock { packages } }
        set { lock.withLock { packages = newValue } }
    }
}

private struct InstallingHomebrew: ToolInstallProvider {
    let id: ProviderID = .homebrew

    func availability(context: ProviderContext) async -> ProviderAvailability {
        ProviderAvailability(providerID: .homebrew, isAvailable: true, executable: "/opt/homebrew/bin/brew")
    }

    func scan(context: ProviderContext, depth: ScanDepth) async throws -> ProviderInventory {
        ProviderInventory(providerID: .homebrew, availability: await availability(context: context), depth: depth, scannedAt: context.now)
    }

    func installPlan(for packages: [InstallRequest], context: ProviderContext) throws -> OperationPlan {
        for package in packages { guard EnvironmentRestore.isValidPackageName(package.packageName) else { throw ProviderError.invalidPackageName(package.packageName) } }
        return OperationPlan(
            kind: .install,
            providerID: .homebrew,
            targets: packages.map { OperationTarget(toolID: $0.toolID, packageName: $0.qualifiedName, displayName: $0.displayName) },
            commands: [Command(executable: "/opt/homebrew/bin/brew", arguments: ["install"] + packages.map(\.qualifiedName))],
            requiresNetwork: true
        )
    }
}

/// Scans but can't install.
private struct ReadOnlyNPM: ToolProvider {
    let id: ProviderID = .npm
    func availability(context: ProviderContext) async -> ProviderAvailability { .unavailable(.npm, reason: "executableNotFound") }
    func scan(context: ProviderContext, depth: ScanDepth) async throws -> ProviderInventory {
        ProviderInventory(providerID: .npm, availability: await availability(context: context), depth: depth, scannedAt: context.now)
    }
}

private struct BoxBuilder: SnapshotBuilding {
    let box: InstalledBox

    func buildSnapshot(discovery: DiscoveryResult, inventories: [ProviderInventory], failedProviders: [ProviderID: String], previous: EnvironmentSnapshot?, depth: ScanDepth, now: Date) async -> EnvironmentSnapshot {
        let tools = box.current.sorted { $0.key < $1.key }.map { name, version in
            let registryID = name.hasPrefix("postgresql") ? "postgresql" : name
            let installation = ToolInstallation(
                id: .package(provider: .homebrew, name: name),
                ownership: Ownership(provider: .homebrew, packageName: name, confidence: .confirmed),
                version: ObservedValue(ToolVersion(version), source: .provider(.homebrew), confidence: .confirmed, observedAt: now),
                installPrefix: "/opt/homebrew/Cellar/\(name)/\(version)",
                linkState: .active,
                isDirect: true
            )
            return Tool(id: ToolID(registryID), identity: ToolIdentity(name: name, displayName: name, category: .developerTool, registryID: registryID), installations: [installation], activeInstallationID: installation.id, health: ToolHealthState(status: .healthy), lastScannedAt: now)
        }
        let providers = inventories.map { ProviderSnapshot(providerID: $0.providerID, availability: $0.availability, freshness: .fresh(now)) }
        return EnvironmentSnapshot(capturedAt: now, depth: depth, shell: discovery.session.environment, pathEntries: [], brokenSymlinks: [], providers: providers, tools: tools, services: [], issues: [])
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

@Suite("Restore operations")
struct RestoreOperationTests {
    fileprivate let box = InstalledBox()
    let runner = StubCommandRunner()
    fileprivate let history = History()

    private func makeCoordinator() async -> OperationCoordinator {
        let scan = ScanCoordinator(discovery: RestoreDiscovery(), providers: [InstallingHomebrew(), ReadOnlyNPM()], builder: BoxBuilder(box: box), repository: Snapshots())
        await scan.scan(depth: .fast)
        let fileSystem = InMemoryFileSystem()
        fileSystem.addExecutable("/opt/homebrew/bin/brew")
        return OperationCoordinator(scan: scan, runner: runner, locks: NoLocks(), trash: NoTrash(), history: history, fileSystem: fileSystem)
    }

    private func run(_ prepared: PreparedOperation, on coordinator: OperationCoordinator) async -> OperationOutcome? {
        var outcome: OperationOutcome?
        for await progress in await coordinator.execute(prepared) {
            if case let .finished(finished) = progress { outcome = finished }
        }
        return outcome
    }

    @Test func preparesAnInstallPlanWithChecks() async throws {
        let coordinator = await makeCoordinator()
        let prepared = try await coordinator.prepare(.install(.homebrew, [
            InstallRequest(packageName: "git", kind: .formula, toolID: "git"),
            InstallRequest(packageName: "terraform", kind: .formula, tap: "hashicorp/tap", toolID: "terraform"),
        ]))
        #expect(prepared.plan.kind == .install)
        #expect(prepared.plan.commands.map(\.arguments) == [["install", "git", "hashicorp/tap/terraform"]])
        #expect(prepared.checks.contains(PreflightCheck(kind: .packageNameValid, outcome: .passed)))
        #expect(prepared.checks.contains(PreflightCheck(kind: .providerAvailable, outcome: .passed, detail: "/opt/homebrew/bin/brew")))
        #expect(prepared.checks.contains(PreflightCheck(kind: .networkRequired, outcome: .info)))
        #expect(!prepared.isBlocked)
        #expect(runner.invocations.isEmpty)
    }

    @Test func refusesHostileNamesAndProvidersWithoutInstall() async {
        let coordinator = await makeCoordinator()
        await #expect(throws: ProviderError.invalidPackageName("--force")) {
            try await coordinator.prepare(.install(.homebrew, [InstallRequest(packageName: "--force", kind: .formula)]))
        }
        await #expect(throws: OperationError.unsupported(.npm)) {
            try await coordinator.prepare(.install(.npm, [InstallRequest(packageName: "@openai/codex", kind: .globalPackage)]))
        }
    }

    @Test func verifiesInstalledPackagesAfterTheRescan() async throws {
        let coordinator = await makeCoordinator()
        let prepared = try await coordinator.prepare(.install(.homebrew, [
            InstallRequest(packageName: "jq", kind: .formula, toolID: "jq"),
            InstallRequest(packageName: "postgresql", kind: .formula, toolID: "postgresql"),
        ]))
        runner.stub("brew", ["install", "jq", "postgresql"], stdout: "==> Pouring jq\n")
        // The alias `postgresql` installs `postgresql@17`; the registry tool still matches.
        box.current = ["jq": "1.8.1", "postgresql@17": "17.6"]

        let outcome = try #require(await run(prepared, on: coordinator))
        #expect(outcome.status == .succeeded)
        #expect(outcome.verifiedVersions == ["homebrew:jq": "1.8.1", "homebrew:postgresql@17": "17.6"])
        let entry = try #require(await history.rows[prepared.plan.id])
        #expect(entry.planKind == .install && entry.status == .succeeded)
    }

    @Test func missingPackageAfterRescanIsUnverified() async throws {
        let coordinator = await makeCoordinator()
        let prepared = try await coordinator.prepare(.install(.homebrew, [InstallRequest(packageName: "wget", kind: .formula)]))
        runner.stub("brew", ["install", "wget"], stdout: "")
        let outcome = try #require(await run(prepared, on: coordinator))
        #expect(outcome.status == .unverified)
    }

    @Test func failedCommandIsRecordedAsFailed() async throws {
        let coordinator = await makeCoordinator()
        let prepared = try await coordinator.prepare(.install(.homebrew, [InstallRequest(packageName: "wget", kind: .formula)]))
        runner.stub("brew", ["install", "wget"], stderr: "Error: No available formula with the name \"wget\".", exitCode: 1)
        let outcome = try #require(await run(prepared, on: coordinator))
        #expect(outcome.status == .failed)
        #expect(outcome.failure?.reason == .commandFailed)
    }
}

@Suite("Environment restore")
struct EnvironmentRestoreTests {
    private func snapshot(available: Set<ProviderID>, installed: [(ProviderID, String, String)] = []) -> EnvironmentSnapshot {
        let now = Date(timeIntervalSince1970: 0)
        let tools = installed.map { provider, name, version in
            let installation = ToolInstallation(id: .package(provider: provider, name: name), ownership: Ownership(provider: provider, packageName: name, confidence: .confirmed), version: ObservedValue(ToolVersion(version), source: .provider(provider), confidence: .confirmed, observedAt: now), linkState: .active, isDirect: true)
            return Tool(id: ToolID(name), identity: ToolIdentity(name: name, displayName: name, category: .runtime, registryID: name), installations: [installation], activeInstallationID: installation.id, health: ToolHealthState(status: .healthy), lastScannedAt: now)
        }
        let providers = [ProviderID.homebrew, .npm, .pnpm, .uv, .pipx, .cargo].map {
            ProviderSnapshot(providerID: $0, availability: ProviderAvailability(providerID: $0, isAvailable: available.contains($0)), freshness: .fresh(now))
        }
        let shell = ShellEnvironment(shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh), path: [], variables: [:], source: .loginShell, capturedAt: now)
        return EnvironmentSnapshot(capturedAt: now, depth: .fast, shell: shell, pathEntries: [], brokenSymlinks: [], providers: providers, tools: tools, services: [], issues: [])
    }

    @Test func stagesRunHomebrewFirstAndReplanAfterEachRescan() throws {
        let template = try #require(EnvironmentRestore.template("ai-cli"))
        let selected = template.items

        let first = EnvironmentRestore.stages(for: selected, snapshot: snapshot(available: [.homebrew]))
        #expect(first.ready.map(\.provider) == [.homebrew])
        #expect(first.ready.first?.requests.map(\.packageName) == ["node", "uv"])
        #expect(first.deferred.map(\.provider) == [.npm, .uv])
        #expect(first.blocked.isEmpty)

        // Node.js and uv from Homebrew make npm and uv available; the rest can run now.
        let after = snapshot(available: [.homebrew, .npm, .uv], installed: [(.homebrew, "node", "24.8.0"), (.homebrew, "uv", "0.9.0")])
        let remaining = EnvironmentRestore.diff(template.profile, snapshot: after).installable.map(\.item)
        let second = EnvironmentRestore.stages(for: remaining, snapshot: after)
        #expect(second.ready.map(\.provider) == [.npm, .uv])
        #expect(second.ready.first?.requests.map(\.packageName) == ["@anthropic-ai/claude-code", "@openai/codex", "@google/gemini-cli", "opencode-ai"])
        #expect(second.ready.last?.requests == [InstallRequest(packageName: "aider-chat", kind: .tool, toolID: "aider")])
        #expect(second.deferred.isEmpty && second.blocked.isEmpty)
    }

    @Test func diffUsesTheRealPackageNameValidator() {
        let profile = EnvironmentProfile(createdAt: Date(), items: [
            ProfileItem(provider: .npm, packageName: "foo; rm -rf ~"),
            ProfileItem(provider: .npm, packageName: "../../etc"),
            ProfileItem(provider: .npm, packageName: "@scope/fine"),
        ])
        let statuses = EnvironmentRestore.diff(profile, snapshot: snapshot(available: [.npm])).entries.map(\.status)
        #expect(statuses == [.unavailable(.invalidPackageName), .unavailable(.invalidPackageName), .pending])
    }

    @Test func profileForToolsKeepsOnlyWhitelistedIDs() {
        let profile = EnvironmentRestore.profile(forTools: ["go", "not-a-tool", "golangci-lint", "go"])
        #expect(profile.items.map(\.id) == ["homebrew-formula:go", "homebrew-formula:golangci-lint"])
        #expect(EnvironmentRestore.candidates.contains { $0.toolID == "claude-code" })
        #expect(EnvironmentRestore.homebrewInstallCommand.hasPrefix("/bin/bash -c "))
        let source = ProfileSource.current(appVersion: "1.0")
        #expect(source.architecture == "arm64" || source.architecture == "x86_64")
        #expect(source.macOSVersion?.first?.isNumber == true)
    }
}
