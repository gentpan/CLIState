@testable import CLIStateProviders
import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing

@Suite("Install plans")
struct InstallPlanTests {
    let runner = StubCommandRunner()
    let fileSystem = InMemoryFileSystem()

    @Test func homebrewTapsFirstThenFormulaeThenCasks() throws {
        let provider = HomebrewProvider(runner: runner, fileSystem: fileSystem)
        let plan = try provider.installPlan(for: [
            InstallRequest(packageName: "git", kind: .formula, toolID: "git", displayName: "Git"),
            InstallRequest(packageName: "ghostty", kind: .cask),
            InstallRequest(packageName: "terraform", kind: .formula, tap: "hashicorp/tap", toolID: "terraform"),
            InstallRequest(packageName: "codexbar", kind: .cask, tap: "steipete/tap"),
            InstallRequest(packageName: "git", kind: .formula),
            InstallRequest(packageName: "vault", kind: .formula, tap: "hashicorp/tap"),
        ], context: TestContext.brew)

        #expect(plan.kind == .install)
        #expect(plan.providerID == .homebrew)
        #expect(plan.requiresNetwork)
        #expect(plan.commands.map(\.executable) == Array(repeating: "/opt/homebrew/bin/brew", count: 4))
        #expect(plan.commands.map(\.arguments) == [
            ["tap", "hashicorp/tap"],
            ["tap", "steipete/tap"],
            ["install", "git", "hashicorp/tap/terraform", "hashicorp/tap/vault"],
            ["install", "--cask", "ghostty", "steipete/tap/codexbar"],
        ])
        for command in plan.commands {
            #expect(command.environmentOverrides["HOMEBREW_NO_AUTO_UPDATE"] == "1")
            #expect(command.environmentOverrides["HOMEBREW_NO_INSTALL_UPGRADE"] == "1")
            #expect(command.environmentOverrides["HOMEBREW_NO_AUTOREMOVE"] == "1")
        }
        #expect(plan.targets.map(\.packageName) == ["git", "ghostty", "hashicorp/tap/terraform", "steipete/tap/codexbar", "hashicorp/tap/vault"])
        #expect(plan.targets.first?.displayName == "Git")
        #expect(plan.targets.first?.toolID == "git")
        #expect(plan.targets.allSatisfy { $0.installationID == nil && $0.fromVersion == nil })
        #expect(runner.invocations.isEmpty, "Building a plan runs nothing")
    }

    @Test func homebrewWithoutTapsHasNoTapStep() throws {
        let plan = try HomebrewProvider(runner: runner, fileSystem: fileSystem)
            .installPlan(for: [InstallRequest(packageName: "jq", kind: .formula)], context: TestContext.brew)
        #expect(plan.commands.map(\.arguments) == [["install", "jq"]])
    }

    @Test func otherProvidersUseTheirOwnInstallCommands() throws {
        let npm = try NPMProvider(runner: runner, fileSystem: fileSystem).installPlan(for: [
            InstallRequest(packageName: "@anthropic-ai/claude-code", kind: .globalPackage),
            InstallRequest(packageName: "@openai/codex", kind: .globalPackage),
        ], context: TestContext.npm)
        #expect(npm.commands.map(\.arguments) == [["install", "-g", "@anthropic-ai/claude-code", "@openai/codex"]])
        #expect(npm.commands.first?.executable == "/Users/tester/.local/bin/npm")

        let pnpm = try PNPMProvider(runner: runner, fileSystem: fileSystem)
            .installPlan(for: [InstallRequest(packageName: "vercel", kind: .globalPackage)], context: TestContext.pnpm)
        #expect(pnpm.commands.map(\.arguments) == [["add", "-g", "vercel"]])

        let uv = try UVProvider(runner: runner, fileSystem: fileSystem).installPlan(for: [
            InstallRequest(packageName: "ruff", kind: .tool),
            InstallRequest(packageName: "aider-chat", kind: .tool),
        ], context: TestContext.uv)
        #expect(uv.commands.map(\.arguments) == [["tool", "install", "ruff"], ["tool", "install", "aider-chat"]])

        let pipx = try PipxProvider(runner: runner, fileSystem: fileSystem)
            .installPlan(for: [InstallRequest(packageName: "poetry", kind: .tool)], context: TestContext.pipx)
        #expect(pipx.commands.map(\.arguments) == [["install", "poetry"]])

        let cargo = try CargoProvider(runner: runner, fileSystem: fileSystem).installPlan(for: [
            InstallRequest(packageName: "cargo-nextest", kind: .tool),
            InstallRequest(packageName: "bat", kind: .tool),
        ], context: TestContext.cargo)
        #expect(cargo.commands.map(\.arguments) == [["install", "--locked", "cargo-nextest"], ["install", "--locked", "bat"]])

        for plan in [npm, pnpm, uv, pipx, cargo] {
            #expect(plan.kind == .install && plan.requiresNetwork)
            #expect(plan.commands.allSatisfy { !$0.executable.contains("sudo") && !$0.arguments.contains("sudo") })
            #expect(plan.mutationScope == plan.providerID.rawValue)
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test("Hostile names never become arguments", arguments: hostilePackageNames)
    func rejectsHostileNames(_ name: String) {
        let request = [InstallRequest(packageName: name, kind: .formula)]
        #expect(throws: ProviderError.self) { try HomebrewProvider(runner: runner, fileSystem: fileSystem).installPlan(for: request, context: TestContext.brew) }
        #expect(throws: ProviderError.self) { try NPMProvider(runner: runner, fileSystem: fileSystem).installPlan(for: [InstallRequest(packageName: name, kind: .globalPackage)], context: TestContext.npm) }
        #expect(throws: ProviderError.self) { try UVProvider(runner: runner, fileSystem: fileSystem).installPlan(for: [InstallRequest(packageName: name, kind: .tool)], context: TestContext.uv) }
        #expect(throws: ProviderError.self) { try CargoProvider(runner: runner, fileSystem: fileSystem).installPlan(for: [InstallRequest(packageName: name, kind: .tool)], context: TestContext.cargo) }
    }

    @Test func rejectsBadTapsKindsAndEmptyRequests() {
        let brew = HomebrewProvider(runner: runner, fileSystem: fileSystem)
        for tap in ["hashicorp", "a/b/c", "-x/tap", "user/../tap", "user/tap name"] {
            #expect(throws: ProviderError.self) { try brew.installPlan(for: [InstallRequest(packageName: "x", kind: .formula, tap: tap)], context: TestContext.brew) }
        }
        #expect(throws: ProviderError.invalidPackageName("other/tap/x")) {
            try brew.installPlan(for: [InstallRequest(packageName: "other/tap/x", kind: .formula, tap: "user/tap")], context: TestContext.brew)
        }
        #expect(throws: ProviderError.unsupportedOperation) { try brew.installPlan(for: [InstallRequest(packageName: "x", kind: .tool)], context: TestContext.brew) }
        #expect(throws: ProviderError.unsupportedOperation) { try brew.installPlan(for: [], context: TestContext.brew) }
        #expect(throws: ProviderError.unsupportedOperation) {
            try NPMProvider(runner: runner, fileSystem: fileSystem).installPlan(for: [InstallRequest(packageName: "x", kind: .globalPackage, tap: "a/b")], context: TestContext.npm)
        }
        #expect(throws: ProviderError.unsupportedOperation) {
            try UVProvider(runner: runner, fileSystem: fileSystem).installPlan(for: [InstallRequest(packageName: "x", kind: .globalPackage)], context: TestContext.uv)
        }
    }

    @Test func missingProviderThrowsUnavailable() {
        #expect(throws: ProviderError.unavailable(.npm)) {
            try NPMProvider(runner: runner, fileSystem: fileSystem).installPlan(for: [InstallRequest(packageName: "x", kind: .globalPackage)], context: TestContext.empty)
        }
        #expect(throws: ProviderError.unavailable(.homebrew)) {
            try HomebrewProvider(runner: runner, fileSystem: fileSystem).installPlan(for: [InstallRequest(packageName: "x", kind: .formula)], context: TestContext.empty)
        }
    }

    @Test func homebrewPreflightRechecksNamesInTheStoredPlan() async throws {
        let provider = HomebrewProvider(runner: runner, fileSystem: fileSystem)
        var plan = try provider.installPlan(for: [InstallRequest(packageName: "jq", kind: .formula, tap: "user/tap")], context: TestContext.brew)
        #expect(await provider.preflight(for: plan, context: TestContext.brew) == [PreflightCheck(kind: .packageNameValid, outcome: .passed)])

        plan.steps.append(.command(Command(executable: "/opt/homebrew/bin/brew", arguments: ["install", "--cask", "-evil"])))
        plan.steps.append(.command(Command(executable: "/opt/homebrew/bin/brew", arguments: ["tap", "one-segment"])))
        let checks = await provider.preflight(for: plan, context: TestContext.brew)
        #expect(checks.first?.outcome == .failed)
        #expect(checks.first?.detail == "-evil\none-segment")
        #expect(runner.invocations.isEmpty, "Install preflight is local only")
    }

    @Test func pnpmInstallNeedsPNPMHome() async throws {
        let provider = PNPMProvider(runner: runner, fileSystem: fileSystem)
        let plan = try provider.installPlan(for: [InstallRequest(packageName: "vercel", kind: .globalPackage)], context: TestContext.pnpm)
        let checks = await provider.preflight(for: plan, context: TestContext.pnpm)
        #expect(checks.map(\.kind) == [.writableLocation])
        #expect(checks.first?.outcome == .failed)
    }

    @Test func mapperReadsTapsFromFullNames() {
        #expect(HomebrewMapper.tap(fromFullName: "hashicorp/tap/terraform") == "hashicorp/tap")
        #expect(HomebrewMapper.tap(fromFullName: "git") == nil)
        #expect(HomebrewMapper.tap(fromFullName: "homebrew/core/git") == nil)
        #expect(HomebrewMapper.tap(fromFullName: "a//b") == nil)
        #expect(HomebrewMapper.tap(fromFullName: nil) == nil)
    }
}
