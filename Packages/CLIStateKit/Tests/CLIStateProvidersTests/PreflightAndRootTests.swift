@testable import CLIStateProviders
import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing

@Suite("pnpm preflight and cargo install root")
struct PreflightAndRootTests {
    private func pnpmPlan(_ kind: OperationKind) -> OperationPlan {
        OperationPlan(kind: kind, providerID: .pnpm, targets: [], commands: [Command(executable: "/Users/tester/Library/pnpm/pnpm", arguments: ["add", "-g", "typescript@latest"])], requiresNetwork: true)
    }

    private func pnpmContext(home: String?) -> ProviderContext {
        var context = TestContext.pnpm
        if let home { context.discovery.session.execution.variables["PNPM_HOME"] = home }
        return context
    }

    @Test func pnpmGlobalWritesNeedPNPMHome() async {
        let fileSystem = InMemoryFileSystem()
        let provider = PNPMProvider(runner: StubCommandRunner(), fileSystem: fileSystem)

        let missing = await provider.preflight(for: pnpmPlan(.update), context: pnpmContext(home: nil))
        #expect(missing.map(\.outcome) == [.failed])
        #expect(missing.first?.detail?.contains("pnpm setup") == true)

        let absent = await provider.preflight(for: pnpmPlan(.uninstall), context: pnpmContext(home: "/Users/tester/Library/pnpm"))
        #expect(absent.map(\.outcome) == [.failed])

        fileSystem.addDirectory("/Users/tester/Library/pnpm")
        let ready = await provider.preflight(for: pnpmPlan(.update), context: pnpmContext(home: "/Users/tester/Library/pnpm"))
        #expect(ready.map(\.outcome) == [.passed])

        #expect(await provider.preflight(for: pnpmPlan(.cleanup(.providerCache)), context: pnpmContext(home: nil)).isEmpty)
    }

    @Test func cargoBinariesFollowCargoInstallRoot() async throws {
        let runner = StubCommandRunner()
        runner.stub("cargo", ["--version"], stdout: "cargo 1.95.0 (abc 2026-08-01)\n")
        runner.stub("cargo", ["install", "--list"], stdout: "ripgrep v15.0.0:\n    rg\n")
        let context = TestContext.make(["cargo": "/opt/homebrew/bin/cargo"], variables: ["CARGO_HOME": "/Users/tester/.cargo", "CARGO_INSTALL_ROOT": "/opt/tools/"])

        let inventory = try await CargoProvider(runner: runner, fileSystem: InMemoryFileSystem()).scan(context: context, depth: .fast)
        #expect(inventory.layout[.cargoHome] == "/Users/tester/.cargo")
        #expect(inventory.layout[.cargoBin] == "/opt/tools/bin")
        #expect(inventory.tools.first?.executablePaths == ["/opt/tools/bin/rg"])
    }
}

@Suite("cargo latest versions")
struct CargoLatestTests {
    @Test func parsesExactMatchOnly() {
        let output = """
        deepseek-tui = "0.8.41"    # DEPRECATED — renamed to codewhale. Install `codewhale` instead (binary: codewhale).
        ... and 4 crates more (use --limit N to see more)
        """
        let result = CargoSearchResult.parse(output, name: "deepseek-tui")
        #expect(result?.version == "0.8.41")
        #expect(result?.isDeprecated == true)
        #expect(CargoSearchResult.parse(#"ripgrep-all = "0.10.9"    # rga"#, name: "ripgrep") == nil)
    }

    @Test func deepScanSetsLatestAndSkipsPinned() async throws {
        let runner = StubCommandRunner()
        runner.stub("cargo", ["--version"], stdout: "cargo 1.95.0\n")
        runner.stub("cargo", ["install", "--list"], stdout: "ripgrep v14.1.1:\n    rg\nmytool v0.1.0 (/Users/tester/src/mytool):\n    mytool\n")
        runner.stub("cargo", ["search", "ripgrep", "--limit", "1", "--color", "never"], stdout: "ripgrep = \"15.0.0\"    # line-oriented search\n")
        let inventory = try await CargoProvider(runner: runner, fileSystem: InMemoryFileSystem()).scan(context: TestContext.cargo, depth: .deep)

        let ripgrep = try #require(inventory.tools.first { $0.packageName == "ripgrep" })
        #expect(ripgrep.latestVersion == "15.0.0")
        #expect(ripgrep.isOutdated == true)
        #expect(!runner.arguments(of: "cargo").contains { $0.first == "search" && $0.contains("mytool") })

        let fast = try await CargoProvider(runner: runner, fileSystem: InMemoryFileSystem()).scan(context: TestContext.cargo, depth: .fast)
        #expect(fast.tools.allSatisfy { $0.latestVersion == nil })
    }
}
