@testable import CLIStateProviders
import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing

@Suite("Homebrew plans")
struct HomebrewPlanTests {
    let runner = StubCommandRunner()
    var provider: HomebrewProvider { HomebrewProvider(runner: runner, fileSystem: InMemoryFileSystem()) }
    let context = TestContext.brew
    let brew = "/opt/homebrew/bin/brew"

    private func expectHomebrewEnvironment(_ plan: OperationPlan, autoremoveDisabled: Bool) {
        for command in plan.commands {
            #expect(command.environmentOverrides["HOMEBREW_NO_AUTO_UPDATE"] == "1")
            #expect(command.environmentOverrides["HOMEBREW_NO_ENV_HINTS"] == "1")
            #expect((command.environmentOverrides["HOMEBREW_NO_AUTOREMOVE"] == "1") == autoremoveDisabled)
            #expect(command.executable == brew)
        }
    }

    @Test func updateSplitsFormulaeAndCasks() throws {
        let tools = [Tools.formula("php", active: "8.5.7", latest: "8.5.10"), Tools.cask("codexbar"), Tools.formula("ffmpeg"), Tools.formula("php")]
        let plan = try provider.updatePlan(for: tools, context: context)
        #expect(plan.kind == .update)
        #expect(plan.providerID == .homebrew)
        #expect(plan.requiresNetwork)
        #expect(plan.mutationScope == "homebrew")
        #expect(plan.trigger == .user)
        #expect(plan.commands.map(\.arguments) == [["upgrade", "php", "ffmpeg"], ["upgrade", "--cask", "codexbar"]])
        #expect(plan.steps.map(\.displayString) == ["brew upgrade php ffmpeg", "brew upgrade --cask codexbar"])
        #expect(plan.targets.count == 3)
        #expect(plan.targets[0] == OperationTarget(installationID: "homebrew:php", packageName: "php", displayName: "php", fromVersion: "8.5.7", toVersion: "8.5.10"))
        expectHomebrewEnvironment(plan, autoremoveDisabled: true)
        #expect(plan.commands.allSatisfy { $0.timeout == nil })
        #expect(runner.invocations.isEmpty, "Plan builders never execute")
    }

    @Test func updateOnlyCasks() throws {
        let plan = try provider.updatePlan(for: [Tools.cask("codexbar")], context: context)
        #expect(plan.commands.map(\.arguments) == [["upgrade", "--cask", "codexbar"]])
    }

    @Test func uninstall() throws {
        let formula = try provider.uninstallPlan(for: Tools.formula("php@8.2"), context: context)
        #expect(formula.kind == .uninstall)
        #expect(!formula.requiresNetwork)
        #expect(formula.commands.map(\.arguments) == [["uninstall", "php@8.2"]])
        #expect(formula.targets.map(\.packageName) == ["php@8.2"])
        expectHomebrewEnvironment(formula, autoremoveDisabled: true)

        let cask = try provider.uninstallPlan(for: Tools.cask("codexbar"), context: context)
        #expect(cask.commands.map(\.arguments) == [["uninstall", "--cask", "codexbar"]])
    }

    @Test("Service plans", arguments: ServiceAction.allCases)
    func service(action: ServiceAction) throws {
        let service = ProviderService(providerID: .homebrew, name: "postgresql@17", status: .running)
        let plan = try provider.servicePlan(action, service: service, context: context)
        #expect(plan.kind == .service(action))
        #expect(plan.commands.map(\.arguments) == [["services", action.rawValue, "postgresql@17"]])
        #expect(plan.targets.map(\.packageName) == ["postgresql@17"])
        #expect(!plan.requiresNetwork)
        expectHomebrewEnvironment(plan, autoremoveDisabled: false)
    }

    @Test func refreshMetadataIsTheOnlyAutoUpdatingCommand() throws {
        let plan = try provider.refreshMetadataPlan(context: context)
        #expect(plan.kind == .refreshMetadata)
        #expect(plan.requiresNetwork)
        #expect(plan.commands.map(\.arguments) == [["update"]])
        let command = try #require(plan.commands.first)
        #expect(command.environmentOverrides["HOMEBREW_NO_AUTO_UPDATE"] == nil)
        #expect(command.environmentOverrides["HOMEBREW_NO_ENV_HINTS"] == "1")
    }

    @Test func cleanupPlans() throws {
        let cleanup = try provider.cleanupPlan(.oldVersions, context: context)
        #expect(cleanup.kind == .cleanup(.oldVersions))
        #expect(cleanup.commands.map(\.arguments) == [["cleanup"]])
        expectHomebrewEnvironment(cleanup, autoremoveDisabled: true)

        let autoremove = try provider.cleanupPlan(.orphanedDependencies, context: context)
        #expect(autoremove.kind == .cleanup(.orphanedDependencies))
        #expect(autoremove.commands.map(\.arguments) == [["autoremove"]])
        expectHomebrewEnvironment(autoremove, autoremoveDisabled: false)

        #expect(throws: ProviderError.unsupportedOperation) { try provider.cleanupPlan(.brokenSymlink, context: context) }
    }

    @Test func rejectsForeignEmptyOrUnresolvable() throws {
        #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [], context: context) }
        #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [Tools.npm("pnpm")], context: context) }
        #expect(throws: ProviderError.unsupportedOperation) { try provider.uninstallPlan(for: Tools.uv("ruff"), context: context) }
        #expect(throws: ProviderError.unavailable(.homebrew)) { try provider.updatePlan(for: [Tools.formula("php")], context: TestContext.empty) }
        #expect(throws: ProviderError.unavailable(.homebrew)) { try provider.refreshMetadataPlan(context: TestContext.empty) }
    }

    @Test("Hostile names are rejected by every plan builder", arguments: hostilePackageNames)
    func hostileNames(name: String) throws {
        #expect(throws: ProviderError.invalidPackageName(name)) { try provider.updatePlan(for: [Tools.formula("php"), Tools.formula(name)], context: context) }
        #expect(throws: ProviderError.invalidPackageName(name)) { try provider.updatePlan(for: [Tools.cask(name)], context: context) }
        #expect(throws: ProviderError.invalidPackageName(name)) { try provider.uninstallPlan(for: Tools.formula(name), context: context) }
        let service = ProviderService(providerID: .homebrew, name: name, status: .stopped)
        #expect(throws: ProviderError.invalidPackageName(name)) { try provider.servicePlan(.start, service: service, context: context) }
        #expect(runner.invocations.isEmpty)
    }
}

@Suite("Homebrew preflight")
struct HomebrewPreflightTests {
    let runner = StubCommandRunner()
    var provider: HomebrewProvider { HomebrewProvider(runner: runner, fileSystem: InMemoryFileSystem()) }
    let context = TestContext.brew

    @Test func parsesRealUpgradeDryRun() throws {
        let parsed = HomebrewOutputParser.upgradeDryRun(try Fixture.string("Homebrew/upgrade-dry-run-php.txt"))
        let installs = parsed.items.filter { $0.change == .install }
        let upgrades = parsed.items.filter { $0.change == .upgrade }
        let dependents = parsed.items.filter { $0.change == .upgradeDependent }
        #expect(installs == [PreflightItem(name: "libpsl", change: .install, toVersion: "0.23.3")])
        #expect(upgrades.count == 9)
        #expect(upgrades.first == PreflightItem(name: "apr-util", change: .upgrade, fromVersion: "1.6.3_1", toVersion: "1.6.5"))
        #expect(upgrades.last == PreflightItem(name: "openldap", change: .upgrade, fromVersion: "2.6.13", toVersion: "2.7.1"))
        #expect(dependents == [PreflightItem(name: "composer", change: .upgradeDependent, fromVersion: "2.9.8", toVersion: "2.10.3")])
        #expect(parsed.requested == [PreflightItem(name: "php", change: .upgrade, fromVersion: "8.5.7", toVersion: "8.5.10")])
    }

    @Test func parsesOtherDryRunShapes() {
        let parsed = HomebrewOutputParser.upgradeDryRun("""
        ==> Would install 2 dependencies for some-cask:
        libfoo libbar
        ==> Would upgrade 2 outdated packages:
        jq 1.7 -> 1.8
        node 25.0.0 -> 26.0.0 (20MB)
        ==> Would upgrade 2 dependents of upgraded formulae:
        yarn 1.22 -> 1.23
        unlinked 3.0
        """)
        #expect(parsed.items == [
            PreflightItem(name: "libfoo", change: .install),
            PreflightItem(name: "libbar", change: .install),
            PreflightItem(name: "yarn", change: .upgradeDependent, fromVersion: "1.22", toVersion: "1.23"),
            PreflightItem(name: "unlinked", change: .upgradeDependent, toVersion: "3.0"),
        ])
        #expect(parsed.requested.map(\.name) == ["jq", "node"])
        #expect(HomebrewOutputParser.upgradeDryRun("") == .init())
    }

    @Test func updatePreflightRunsDryRunForEachStep() async throws {
        try runner.stub("brew", ["upgrade", "--dry-run", "php"], fixture: "Homebrew/upgrade-dry-run-php.txt", stderr: try Fixture.string("Homebrew/stderr-warnings.txt"))
        try runner.stub("brew", ["upgrade", "--dry-run", "--cask", "codexbar"], fixture: "Homebrew/upgrade-dry-run-cask.txt")
        let plan = try provider.updatePlan(for: [Tools.formula("php"), Tools.cask("codexbar")], context: context)

        let checks = await provider.preflight(for: plan, context: context)
        let check = try #require(checks.first)
        #expect(checks.count == 1)
        #expect(check.kind == .dryRun)
        #expect(check.outcome == .warning)
        #expect(check.items.count == 11)
        #expect(check.items.filter { $0.change == .upgrade }.count == 9)
        #expect(check.detail == "php 8.5.7 -> 8.5.10\ncodexbar 0.56.4 -> 0.60.0")

        #expect(runner.arguments(of: "brew") == [["upgrade", "--dry-run", "php"], ["upgrade", "--dry-run", "--cask", "codexbar"]])
        for command in runner.commands {
            #expect(command.environmentOverrides["HOMEBREW_NO_AUTO_UPDATE"] == "1")
            #expect(command.environmentOverrides["HOMEBREW_NO_ENV_HINTS"] == "1")
            #expect(command.timeout == .seconds(60))
        }
    }

    @Test func dryRunWithoutCollateralChangesPasses() async throws {
        try runner.stub("brew", ["upgrade", "--dry-run", "--cask", "codexbar"], fixture: "Homebrew/upgrade-dry-run-cask.txt")
        let plan = try provider.updatePlan(for: [Tools.cask("codexbar")], context: context)
        let checks = await provider.preflight(for: plan, context: context)
        #expect(checks == [PreflightCheck(kind: .dryRun, outcome: .passed, detail: "codexbar 0.56.4 -> 0.60.0")])
    }

    @Test func failedDryRunBlocks() async throws {
        runner.stub("brew", ["upgrade", "--dry-run", "jq"], stderr: "Warning: You are using macOS 27.\nError: jq not installed\n", exitCode: 1)
        let plan = try provider.updatePlan(for: [Tools.formula("jq")], context: context)
        let checks = await provider.preflight(for: plan, context: context)
        #expect(checks == [PreflightCheck(kind: .dryRun, outcome: .failed, detail: "Error: jq not installed")])
        #expect(checks.first?.isBlocking == true)
    }

    @Test func uninstallPreflightListsReverseDependencies() async throws {
        runner.stub("brew", ["uses", "--installed", "php"], stdout: "composer\n")
        let plan = try provider.uninstallPlan(for: Tools.formula("php"), context: context)
        let checks = await provider.preflight(for: plan, context: context)
        #expect(checks == [PreflightCheck(kind: .reverseDependencies, outcome: .failed, items: [PreflightItem(name: "composer", change: .dependent)])])
        #expect(checks.first?.isBlocking == true)
        let uses = try #require(runner.commands.first)
        #expect(uses.arguments == ["uses", "--installed", "php"])
        #expect(uses.environmentOverrides["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    }

    @Test func uninstallWithoutDependentsPasses() async throws {
        runner.stub("brew", ["uses", "--installed", "ffmpeg"], stdout: "")
        let plan = try provider.uninstallPlan(for: Tools.formula("ffmpeg"), context: context)
        #expect(await provider.preflight(for: plan, context: context) == [PreflightCheck(kind: .reverseDependencies, outcome: .passed)])
    }

    @Test func caskUninstallSkipsBrewUses() async throws {
        let plan = try provider.uninstallPlan(for: Tools.cask("codexbar"), context: context)
        #expect(await provider.preflight(for: plan, context: context) == [PreflightCheck(kind: .reverseDependencies, outcome: .passed)])
        #expect(runner.invocations.isEmpty)
    }

    @Test func tamperedPlanIsRejectedWithoutRunning() async throws {
        var plan = try provider.updatePlan(for: [Tools.formula("php")], context: context)
        plan.steps = [.command(Command(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "php; rm -rf ~"]))]
        let checks = await provider.preflight(for: plan, context: context)
        #expect(checks.map(\.kind) == [.packageNameValid])
        #expect(checks.first?.outcome == .failed)
        #expect(runner.invocations.isEmpty)
    }

    @Test func ignoresOtherProvidersAndKinds() async throws {
        let npmPlan = OperationPlan(kind: .update, providerID: .npm, targets: [], commands: [], requiresNetwork: true)
        #expect(await provider.preflight(for: npmPlan, context: context).isEmpty)
        let refresh = try provider.refreshMetadataPlan(context: context)
        #expect(await provider.preflight(for: refresh, context: context).isEmpty)
        let missing = await provider.preflight(for: refresh, context: TestContext.empty)
        #expect(missing.map(\.outcome) == [.failed])
    }
}

@Suite("Homebrew cleanup")
struct HomebrewCleanupTests {
    let runner = StubCommandRunner()
    var provider: HomebrewProvider { HomebrewProvider(runner: runner, fileSystem: InMemoryFileSystem()) }
    let context = TestContext.brew
    let layout = HomebrewMapper.layout(prefix: "/opt/homebrew")

    func stubDryRuns(cleanup: String? = "Homebrew/cleanup-dry-run.txt", autoremove: String? = "Homebrew/autoremove-dry-run.txt") throws {
        runner.stub("brew", ["--prefix"], stdout: "/opt/homebrew\n")
        if let cleanup { try runner.stub("brew", ["cleanup", "--dry-run"], fixture: cleanup) } else { runner.stub("brew", ["cleanup", "--dry-run"], stdout: "") }
        if let autoremove { try runner.stub("brew", ["autoremove", "--dry-run"], fixture: autoremove) } else { runner.stub("brew", ["autoremove", "--dry-run"], stdout: "") }
    }

    @Test func parsesCleanupDryRun() throws {
        let parsed = HomebrewOutputParser.cleanupDryRun(try Fixture.string("Homebrew/cleanup-dry-run.txt"), layout: layout)
        #expect(parsed.paths.count == 10)
        #expect(parsed.paths.contains("/opt/homebrew/bin/codexbar"))
        #expect(parsed.paths.contains("/opt/homebrew/lib/gio"))
        #expect(parsed.paths.contains("/Users/tester/Library/Logs/Homebrew/php"))
        #expect(parsed.reclaimableBytes == 303_800_000)
        #expect(parsed.items == [
            PreflightItem(name: "ada-url", change: .remove, fromVersion: "3.4.4"),
            PreflightItem(name: "ca-certificates", change: .remove, fromVersion: "2026-03-19"),
            PreflightItem(name: "openssl@3", change: .remove, fromVersion: "3.6.2"),
            PreflightItem(name: "openssl@3", change: .remove, fromVersion: "3.6.3"),
            PreflightItem(name: "python@3.14", change: .remove, fromVersion: "3.14.4_1"),
        ])
    }

    @Test func cleanupDryRunWithoutTotalSumsSizes() {
        let parsed = HomebrewOutputParser.cleanupDryRun("""
        Would remove: /Users/tester/Library/Caches/Homebrew/downloads/abc--php-8.5.7.bottle.tar.gz (29.3MB)
        Would remove: /Users/tester/Library/Caches/Homebrew/My Cache (old) (2 files, 1KB)
        Would prune 3 files from: /Users/tester/Library/Caches/Homebrew/api
        """, layout: layout)
        #expect(parsed.paths == [
            "/Users/tester/Library/Caches/Homebrew/downloads/abc--php-8.5.7.bottle.tar.gz",
            "/Users/tester/Library/Caches/Homebrew/My Cache (old)",
            "/Users/tester/Library/Caches/Homebrew/api",
        ])
        #expect(parsed.reclaimableBytes == 29_301_000)
        #expect(parsed.items.isEmpty)
        #expect(HomebrewOutputParser.cleanupDryRun("", layout: layout).isEmpty)
    }

    @Test("Homebrew sizes use decimal units", arguments: [
        ("64B", Int64(64)), ("1MB", 1_000_000), ("237.5KB", 237_500), ("303.8MB", 303_800_000), ("1.2GB", 1_200_000_000),
    ])
    func byteCount(token: String, bytes: Int64) {
        #expect(HomebrewOutputParser.byteCount(token) == bytes)
    }

    @Test func parsesAutoremoveDryRun() throws {
        #expect(HomebrewOutputParser.autoremoveDryRun(try Fixture.string("Homebrew/autoremove-dry-run.txt")) == ["cffi", "pycparser"])
        #expect(HomebrewOutputParser.autoremoveDryRun("").isEmpty)
    }

    @Test func candidatesCarryExecutablePlans() async throws {
        try stubDryRuns()
        let candidates = try await provider.cleanupCandidates(context: context)
        #expect(candidates.map(\.id) == ["oldVersions:homebrew", "orphanedDependencies:homebrew"])

        let old = candidates[0]
        #expect(old.kind == .oldVersions)
        #expect(old.risk == .low)
        #expect(old.reclaimableBytes == 303_800_000)
        #expect(old.paths.count == 10)
        #expect(old.plan?.commands.map(\.arguments) == [["cleanup"]])
        #expect(old.plan?.kind == .cleanup(.oldVersions))

        let orphans = candidates[1]
        #expect(orphans.kind == .orphanedDependencies)
        #expect(orphans.risk == .medium)
        #expect(orphans.items == [PreflightItem(name: "cffi", change: .remove), PreflightItem(name: "pycparser", change: .remove)])
        #expect(orphans.plan?.commands.map(\.arguments) == [["autoremove"]])
        #expect(orphans.plan?.targets.map(\.packageName) == ["cffi", "pycparser"])

        for command in runner.commands {
            #expect(command.environmentOverrides["HOMEBREW_NO_AUTO_UPDATE"] == "1")
            #expect(command.environmentOverrides["HOMEBREW_NO_ENV_HINTS"] == "1")
        }
        let dryRun = try #require(runner.commands.first { $0.arguments == ["cleanup", "--dry-run"] })
        #expect(dryRun.environmentOverrides["HOMEBREW_NO_AUTOREMOVE"] == "1")
        #expect(dryRun.timeout == .seconds(60))
    }

    @Test func nothingToClean() async throws {
        try stubDryRuns(cleanup: nil, autoremove: nil)
        #expect(try await provider.cleanupCandidates(context: context).isEmpty)
    }

    @Test func oneFailingDryRunKeepsTheOther() async throws {
        try stubDryRuns()
        runner.stub("brew", ["autoremove", "--dry-run"], stderr: "Error: x", exitCode: 1)
        #expect(try await provider.cleanupCandidates(context: context).map(\.kind) == [.oldVersions])

        runner.stub("brew", ["cleanup", "--dry-run"], stderr: "Error: y", exitCode: 1)
        await #expect(throws: ProviderError.self) { try await provider.cleanupCandidates(context: context) }
    }
}
