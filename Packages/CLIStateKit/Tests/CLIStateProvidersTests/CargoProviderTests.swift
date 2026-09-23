@testable import CLIStateProviders
import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing

@Suite("Cargo provider")
struct CargoProviderTests {
    static let home = "/Users/tester/.cargo"

    let runner = StubCommandRunner()
    let fileSystem = InMemoryFileSystem()
    var provider: CargoProvider { CargoProvider(runner: runner, fileSystem: fileSystem) }
    let context = TestContext.cargo

    init() throws {
        try runner.stub("cargo", ["--version"], fixture: "Cargo/version.txt")
        try runner.stub("cargo", ["install", "--list"], fixture: "Cargo/install-list.txt")
    }

    func tool(_ inventory: ProviderInventory, _ name: String) throws -> ProviderTool {
        try #require(inventory.tools.first { $0.packageName == name })
    }

    // MARK: Parsing

    @Test func parsesVersion() throws {
        #expect(CargoInstallListParser.version(from: try Fixture.string("Cargo/version.txt")) == "1.95.0")
        #expect(CargoInstallListParser.version(from: "rustc 1.95.0") == nil)
        #expect(CargoInstallListParser.version(from: "") == nil)
    }

    @Test func parsesInstallList() throws {
        let entries = CargoInstallListParser.parse(try Fixture.string("Cargo/install-list.txt"))
        #expect(entries == [
            .init(name: "deepseek-tui", version: "0.8.20", source: nil, binaries: ["deepseek-tui"]),
            .init(name: "deepseek-tui-cli", version: "0.8.20", source: nil, binaries: ["deepseek"]),
            .init(name: "git-tool", version: "1.2.0-beta.1", source: .git("https://github.com/example/git-tool?branch=main#1a2b3c4d"), binaries: ["git-tool", "git-tool-helper"]),
            .init(name: "local-tool", version: "0.1.0", source: .path("/Users/tester/src/my tools (fork)/local-tool"), binaries: ["local-tool"]),
            .init(name: "private-crate", version: "2.0.0", source: .other("registry `my-registry`"), binaries: ["private-crate"]),
        ])
    }

    @Test func parsesEmptyAndMalformedOutput() {
        #expect(CargoInstallListParser.parse("").isEmpty)
        #expect(CargoInstallListParser.parse("\n\n").isEmpty)
        let entries = CargoInstallListParser.parse("""
            orphan-binary
        warning: something odd
        not a header
        noversion:
        bad 1.0.0:
        v:
        ripdir v0.3.0 (dir /Users/tester/vendor):
        \u{1B}[1mripgrep\u{1B}[0m v14.1.1:
            rg
        trailing v1.0.0 garbage:
            trailing
        crate-without-bins v0.1.0:
        """)
        #expect(entries.map(\.name) == ["ripdir", "ripgrep", "trailing", "crate-without-bins"])
        #expect(entries[0].source == .other("dir /Users/tester/vendor"))
        #expect(entries[1].binaries == ["rg"])
        #expect(entries[1].source == nil)
        #expect(entries[2].source == .other("garbage"))
        #expect(entries[3].binaries.isEmpty)
    }

    // MARK: Scan

    @Test func fastScan() async throws {
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.providerID == .cargo)
        #expect(inventory.availability.version == "1.95.0")
        #expect(inventory.availability.executable == "/opt/homebrew/bin/cargo")
        #expect(inventory.layout[.cargoHome] == Self.home)
        #expect(inventory.layout[.cargoBin] == Self.home + "/bin")
        #expect(inventory.tools.map(\.packageName) == ["deepseek-tui", "deepseek-tui-cli", "git-tool", "local-tool", "private-crate"])
        #expect(inventory.warnings.isEmpty)

        let cli = try tool(inventory, "deepseek-tui-cli")
        #expect(cli.kind == .tool)
        #expect(cli.installationID == "cargo:deepseek-tui-cli")
        #expect(cli.installedVersions == ["0.8.20"])
        #expect(cli.activeVersion == "0.8.20")
        #expect(cli.latestVersion == nil)
        #expect(cli.isOutdated == nil)
        #expect(cli.isPinned == false)
        #expect(cli.isDirect == true)
        #expect(cli.installPrefix == Self.home + "/bin")
        #expect(cli.executableNames == ["deepseek"])
        #expect(cli.executablePaths == [Self.home + "/bin/deepseek"])

        #expect(try tool(inventory, "git-tool").isPinned)
        #expect(try tool(inventory, "local-tool").isPinned)
        #expect(try tool(inventory, "private-crate").isPinned)
        #expect(try tool(inventory, "git-tool").executablePaths == [Self.home + "/bin/git-tool", Self.home + "/bin/git-tool-helper"])

        #expect(Set(runner.arguments(of: "cargo")) == [["--version"], ["install", "--list"]])
        #expect(runner.commands.allSatisfy { $0.timeout == .seconds(30) && $0.environmentOverrides.isEmpty })
    }

    /// Deep scans add crates.io lookups; without network (no stubs) nothing else changes.
    @Test func deepScanWithoutLookupsMatchesFastScan() async throws {
        let deep = try await provider.scan(context: context, depth: .deep)
        #expect(deep.depth == .deep)
        #expect(deep.tools == (try await provider.scan(context: context, depth: .fast)).tools)
        let searches = runner.commands.filter { $0.arguments.first == "search" }
        #expect(!searches.isEmpty)
        #expect(searches.allSatisfy { $0.timeout == .seconds(20) })
        #expect(!searches.contains { ["git-tool", "local-tool", "private-crate"].contains($0.arguments[1]) }, "pinned crates are never looked up")
    }

    @Test("CARGO_HOME comes from the shell", arguments: [
        ("/Users/tester/dev/cargo", "/Users/tester/dev/cargo"),
        ("/Users/tester/dev/cargo/", "/Users/tester/dev/cargo"),
        ("relative/cargo", "/Users/tester/.cargo"),
        ("", "/Users/tester/.cargo"),
    ])
    func cargoHomeVariable(value: String, expected: String) async throws {
        let context = TestContext.make(["cargo": "/opt/homebrew/bin/cargo"], variables: ["CARGO_HOME": value])
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.layout[.cargoHome] == expected)
        #expect(inventory.layout[.cargoBin] == expected + "/bin")
        #expect(try tool(inventory, "deepseek-tui").executablePaths == [expected + "/bin/deepseek-tui"])
    }

    @Test func emptyList() async throws {
        runner.stub("cargo", ["install", "--list"], stdout: "")
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.tools.isEmpty)
        #expect(inventory.layout[.cargoHome] == Self.home)
    }

    @Test func warningsAndFailures() async throws {
        runner.stub("cargo", ["install", "--list"], stdout: "ripgrep v14.1.1:\n    rg\n", stderr: "warning: `/Users/tester/.cargo/config` is deprecated\n")
        runner.stub("cargo", ["--version"], stderr: "boom", exitCode: 1)
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.tools.map(\.packageName) == ["ripgrep"])
        #expect(inventory.availability.version == nil)
        #expect(inventory.warnings == ["boom", "warning: `/Users/tester/.cargo/config` is deprecated"])

        runner.stub("cargo", ["install", "--list"], stderr: "error: failed to parse manifest", exitCode: 101)
        await #expect(throws: ProviderError.commandFailed(.cargo, command: "cargo install --list", exitCode: 101, stderr: "error: failed to parse manifest")) {
            try await provider.scan(context: context, depth: .fast)
        }
    }

    @Test func unavailableWithoutCargo() async throws {
        #expect(await provider.availability(context: TestContext.empty).isAvailable == false)
        await #expect(throws: ProviderError.unavailable(.cargo)) { try await provider.scan(context: TestContext.empty, depth: .fast) }
        #expect(throws: ProviderError.unavailable(.cargo)) { try provider.uninstallPlan(for: Tools.cargo("ripgrep"), context: TestContext.empty) }

        let availability = await provider.availability(context: context)
        #expect(availability.isAvailable)
        #expect(availability.version == "1.95.0")
        runner.stub("cargo", ["--version"], exitCode: 1)
        #expect(await provider.availability(context: context).reason == "versionCommandFailed")
    }

    // MARK: Plans

    @Test func plans() throws {
        let update = try provider.updatePlan(for: [Tools.cargo("deepseek-tui"), Tools.cargo("deepseek-tui-cli"), Tools.cargo("deepseek-tui")], context: context)
        #expect(update.kind == .update)
        #expect(update.providerID == .cargo)
        #expect(update.requiresNetwork)
        #expect(update.commands.map(\.arguments) == [["install", "deepseek-tui"], ["install", "deepseek-tui-cli"]])
        #expect(update.commands.map(\.executable) == ["/opt/homebrew/bin/cargo", "/opt/homebrew/bin/cargo"])
        #expect(update.targets.map(\.installationID) == [InstallationID("cargo:deepseek-tui"), InstallationID("cargo:deepseek-tui-cli")])
        #expect(update.targets.map(\.fromVersion) == ["0.8.20", "0.8.20"])
        #expect(update.steps.map(\.displayString) == ["cargo install deepseek-tui", "cargo install deepseek-tui-cli"])

        let uninstall = try provider.uninstallPlan(for: Tools.cargo("deepseek-tui"), context: context)
        #expect(uninstall.kind == .uninstall)
        #expect(!uninstall.requiresNetwork)
        #expect(uninstall.commands.map(\.arguments) == [["uninstall", "deepseek-tui"]])
        #expect(uninstall.targets.map(\.packageName) == ["deepseek-tui"])
        #expect(runner.invocations.isEmpty)

        #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [], context: context) }
        #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [Tools.uv("ruff")], context: context) }
        #expect(throws: ProviderError.unsupportedOperation) { try provider.uninstallPlan(for: Tools.pipx("black"), context: context) }
    }

    @Test func pathAndGitCratesCannotBeUpdated() async throws {
        let inventory = try await provider.scan(context: context, depth: .fast)
        for name in ["git-tool", "local-tool", "private-crate"] {
            let pinned = try tool(inventory, name)
            #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [pinned], context: context) }
            #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [Tools.cargo("ripgrep"), pinned], context: context) }
            // Removing them is still fine.
            #expect(try provider.uninstallPlan(for: pinned, context: context).commands.map(\.arguments) == [["uninstall", name]])
        }
        let registry = try tool(inventory, "deepseek-tui")
        #expect(try provider.updatePlan(for: [registry], context: context).commands.map(\.arguments) == [["install", "deepseek-tui"]])
    }

    @Test("Hostile names are rejected", arguments: hostilePackageNames)
    func hostileNames(name: String) throws {
        #expect(throws: ProviderError.invalidPackageName(name)) { try provider.updatePlan(for: [Tools.cargo(name)], context: context) }
        #expect(throws: ProviderError.invalidPackageName(name)) { try provider.uninstallPlan(for: Tools.cargo(name), context: context) }
        #expect(runner.invocations.isEmpty)
    }
}
