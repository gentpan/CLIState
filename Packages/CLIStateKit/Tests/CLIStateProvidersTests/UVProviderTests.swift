@testable import CLIStateProviders
import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing

@Suite("uv provider")
struct UVProviderTests {
    let runner = StubCommandRunner()
    let fileSystem = InMemoryFileSystem()
    var provider: UVProvider { UVProvider(runner: runner, fileSystem: fileSystem) }
    let context = TestContext.uv

    init() throws {
        try runner.stub("uv", ["--version"], fixture: "UV/version.txt")
        try runner.stub("uv", ["tool", "dir"], fixture: "UV/tool-dir.txt")
        runner.stub("uv", ["tool", "dir", "--bin"], stdout: "/Users/tester/.local/bin\n")
        try runner.stub("uv", ["tool", "list", "--show-paths"], fixture: "UV/tool-list-show-paths.txt")
        try runner.stub("uv", ["tool", "list", "--outdated"], fixture: "UV/tool-list-outdated.txt")
    }

    // MARK: Parsing

    @Test func parsesVersion() throws {
        #expect(UVToolListParser.version(from: try Fixture.string("UV/version.txt")) == "0.11.8")
        #expect(UVToolListParser.version(from: "something else") == nil)
    }

    @Test func parsesShowPaths() throws {
        let entries = UVToolListParser.parse(try Fixture.string("UV/tool-list-show-paths.txt"))
        #expect(entries == [UVToolListParser.Entry(
            name: "kimi-cli",
            version: "1.49.0",
            latestVersion: nil,
            path: "/Users/tester/.local/share/uv/tools/kimi-cli",
            executables: [
                .init(name: "kimi", path: "/Users/tester/.local/bin/kimi"),
                .init(name: "kimi-cli", path: "/Users/tester/.local/bin/kimi-cli"),
            ]
        )])
    }

    @Test func parsesOutdatedWithoutPaths() throws {
        let entries = UVToolListParser.parse(try Fixture.string("UV/tool-list-outdated.txt"))
        #expect(entries == [UVToolListParser.Entry(
            name: "kimi-cli",
            version: "1.49.0",
            latestVersion: "1.50.0",
            path: nil,
            executables: [.init(name: "kimi", path: nil), .init(name: "kimi-cli", path: nil)]
        )])
    }

    @Test func parsesMixedOutput() {
        let entries = UVToolListParser.parse("""
        - orphan (/nowhere)
        ruff v0.14.0 [required: >=0.13] [latest: 0.15.1] (/Users/tester/Library/Application Support/uv/tools/ruff)
        - ruff (/Users/tester/my bin/ruff)
        No tools installed
        httpie v3.2.4
        - http
        - https
        """)
        #expect(entries.map(\.name) == ["ruff", "httpie"])
        #expect(entries[0].latestVersion == "0.15.1")
        #expect(entries[0].path == "/Users/tester/Library/Application Support/uv/tools/ruff")
        #expect(entries[0].executables == [.init(name: "ruff", path: "/Users/tester/my bin/ruff")])
        #expect(entries[1].executables.map(\.name) == ["http", "https"])
        #expect(UVToolListParser.parse("").isEmpty)
    }

    // MARK: Scan

    @Test func fastScan() async throws {
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.availability.version == "0.11.8")
        #expect(inventory.layout[.uvToolDir] == "/Users/tester/.local/share/uv/tools")
        #expect(inventory.layout[.uvToolBinDir] == "/Users/tester/.local/bin")
        let tool = try #require(inventory.tools.first)
        #expect(inventory.tools.count == 1)
        #expect(tool.packageName == "kimi-cli")
        #expect(tool.kind == .tool)
        #expect(tool.installationID == "uv:kimi-cli")
        #expect(tool.installedVersions == ["1.49.0"])
        #expect(tool.activeVersion == "1.49.0")
        #expect(tool.installPrefix == "/Users/tester/.local/share/uv/tools/kimi-cli")
        #expect(tool.executableNames == ["kimi", "kimi-cli"])
        #expect(tool.executablePaths == ["/Users/tester/.local/bin/kimi", "/Users/tester/.local/bin/kimi-cli"])
        #expect(tool.isOutdated == nil)
        #expect(tool.latestVersion == nil)
        #expect(Set(runner.arguments(of: "uv")) == [["--version"], ["tool", "dir"], ["tool", "dir", "--bin"], ["tool", "list", "--show-paths"]])
        #expect(runner.commands.allSatisfy { $0.timeout == .seconds(30) })
    }

    @Test func deepScanAddsLatest() async throws {
        let inventory = try await provider.scan(context: context, depth: .deep)
        let tool = try #require(inventory.tools.first)
        #expect(tool.latestVersion == "1.50.0")
        #expect(tool.isOutdated == true)
        let outdated = try #require(runner.commands.first { $0.arguments == ["tool", "list", "--outdated"] })
        #expect(outdated.timeout == .seconds(60))

        runner.stub("uv", ["tool", "list", "--outdated"], stdout: "")
        let current = try #require(try await provider.scan(context: context, depth: .deep).tools.first)
        #expect(current.isOutdated == false)
        #expect(current.latestVersion == nil)
    }

    @Test func warningsAndFailures() async throws {
        runner.stub("uv", ["tool", "list", "--show-paths"], stdout: "", stderr: "warning: Ignoring malformed tool `broken` (run `uv tool uninstall broken`)\n")
        runner.stub("uv", ["tool", "list", "--outdated"], stderr: "error: Failed to fetch\n", exitCode: 2)
        let inventory = try await provider.scan(context: context, depth: .deep)
        #expect(inventory.tools.isEmpty)
        #expect(inventory.warnings.first == "warning: Ignoring malformed tool `broken` (run `uv tool uninstall broken`)")
        #expect(inventory.warnings.contains("error: Failed to fetch"))
        #expect(inventory.warnings.contains { $0.contains("uv tool list --outdated failed (exit 2)") })

        runner.stub("uv", ["tool", "list", "--show-paths"], stderr: "error: boom", exitCode: 2)
        await #expect(throws: ProviderError.commandFailed(.uv, command: "uv tool list --show-paths", exitCode: 2, stderr: "error: boom")) {
            try await provider.scan(context: context, depth: .fast)
        }
    }

    @Test func unavailableWithoutUV() async throws {
        #expect(await provider.availability(context: TestContext.empty).isAvailable == false)
        await #expect(throws: ProviderError.unavailable(.uv)) { try await provider.scan(context: TestContext.empty, depth: .fast) }
        #expect(await provider.availability(context: context).version == "0.11.8")
    }

    // MARK: Plans

    @Test func plans() throws {
        let update = try provider.updatePlan(for: [Tools.uv("kimi-cli"), Tools.uv("ruff")], context: context)
        #expect(update.kind == .update)
        #expect(update.requiresNetwork)
        #expect(update.commands.map(\.arguments) == [["tool", "upgrade", "kimi-cli", "ruff"]])
        #expect(update.commands.map(\.executable) == ["/Users/tester/.local/bin/uv"])
        #expect(update.targets.map(\.toVersion) == ["1.50.0", "1.50.0"])

        let uninstall = try provider.uninstallPlan(for: Tools.uv("kimi-cli"), context: context)
        #expect(uninstall.kind == .uninstall)
        #expect(uninstall.commands.map(\.arguments) == [["tool", "uninstall", "kimi-cli"]])

        let cleanup = try provider.cleanupPlan(context: context)
        #expect(cleanup.kind == .cleanup(.providerCache))
        #expect(cleanup.commands.map(\.arguments) == [["cache", "prune"]])
        #expect(runner.invocations.isEmpty)

        #expect(throws: ProviderError.unsupportedOperation) { try provider.uninstallPlan(for: Tools.npm("pnpm"), context: context) }
    }

    @Test("Hostile names are rejected", arguments: hostilePackageNames)
    func hostileNames(name: String) throws {
        #expect(throws: ProviderError.invalidPackageName(name)) { try provider.updatePlan(for: [Tools.uv(name)], context: context) }
        #expect(throws: ProviderError.invalidPackageName(name)) { try provider.uninstallPlan(for: Tools.uv(name), context: context) }
        #expect(runner.invocations.isEmpty)
    }

    // MARK: Cleanup

    @Test func cacheCandidate() async throws {
        runner.stub("uv", ["cache", "dir"], stdout: "/Users/tester/.cache/uv\n")
        runner.stub("du", ["-sk", "/Users/tester/.cache/uv"], stdout: "10\t/Users/tester/.cache/uv\n")
        fileSystem.addDirectory("/Users/tester/.cache/uv")
        let candidates = try await provider.cleanupCandidates(context: context)
        #expect(candidates.map(\.id) == ["providerCache:uv"])
        #expect(candidates.first?.reclaimableBytes == 10_240)
        #expect(candidates.first?.risk == .low)
        #expect(candidates.first?.plan?.commands.map(\.arguments) == [["cache", "prune"]])

        fileSystem.remove("/Users/tester/.cache/uv")
        #expect(try await provider.cleanupCandidates(context: context).isEmpty)
    }
}

@Suite("Package name validation")
struct PackageNameValidatorTests {
    @Test("Accepts real package names", arguments: [
        "php", "php@8.2", "python@3.14", "@anthropic-ai/claude-code", "user/tap/name", "kimi-cli",
        "libxml++3", "hdrhistogram_c", "font-maple-mono-nf-cn", "0.0.0-next", "a",
    ])
    func accepts(name: String) {
        #expect(PackageNameValidator.isValid(name))
    }

    @Test("Rejects hostile names", arguments: hostilePackageNames)
    func rejects(name: String) {
        #expect(!PackageNameValidator.isValid(name))
        #expect(throws: ProviderError.invalidPackageName(name)) { try PackageNameValidator.validate(name) }
    }

    @Test func commandsKeepArgumentsSeparate() {
        let command = Command(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "foo; rm -rf ~"])
        #expect(command.arguments.count == 2)
        #expect(command.displayString == "brew upgrade 'foo; rm -rf ~'")
    }
}

@Suite("Output text")
struct OutputTextTests {
    @Test func groupsWarningBlocks() throws {
        let warnings = OutputText.warnings(fromStderr: try Fixture.string("Homebrew/stderr-warnings.txt"))
        #expect(warnings.count == 2)
        #expect(OutputText.warnings(fromStderr: "\n\n").isEmpty)
        #expect(OutputText.warnings(fromStderr: "plain line\nsecond") == ["plain line\nsecond"])
        #expect(OutputText.warnings(fromStderr: "\u{1B}[33mWarning:\u{1B}[0m colored") == ["Warning: colored"])
    }

    @Test func parsesDiskUsage() {
        #expect(DiskUsage.parseBytes("2048\t/Users/tester/.npm/_cacache\n") == 2_097_152)
        #expect(DiskUsage.parseBytes("du: cannot access") == nil)
        #expect(DiskUsage.parseBytes("") == nil)
    }
}
