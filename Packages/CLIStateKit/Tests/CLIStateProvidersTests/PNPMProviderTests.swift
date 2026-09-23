@testable import CLIStateProviders
import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing

@Suite("pnpm provider")
struct PNPMProviderTests {
    static let home = "/Users/tester/Library/pnpm"
    static let root = home + "/global/5/node_modules"
    static let store = home + "/store/v10"
    static let pnpmPath = home + "/pnpm"
    static let listArguments = ["list", "-g", "--depth=0", "--json"]
    static let outdatedArguments = ["outdated", "-g", "--format", "json"]

    let runner = StubCommandRunner()
    let fileSystem = InMemoryFileSystem()
    var provider: PNPMProvider { PNPMProvider(runner: runner, fileSystem: fileSystem) }
    let context = TestContext.pnpm

    init() throws {
        runner.stub("pnpm", ["--version"], stdout: "10.33.0\n")
        runner.stub("pnpm", ["root", "-g"], stdout: Self.root + "\n")
        runner.stub("pnpm", ["bin", "-g"], stdout: Self.home + "\n")
        try runner.stub("pnpm", Self.listArguments, fixture: "PNPM/list-global.json")
        try runner.stub("pnpm", Self.outdatedArguments, fixture: "PNPM/outdated-global.json", exitCode: 1)

        // Virtual-store directory reported by `pnpm list`.
        fileSystem.addFile(
            Self.root + "/.pnpm/@anthropic-ai+claude-code@2.1.236/node_modules/@anthropic-ai/claude-code/package.json",
            contents: Data(#"{"name":"@anthropic-ai/claude-code","description":"Claude Code","homepage":"https://github.com/anthropics/claude-code","bin":{"claude":"cli.js"}}"#.utf8)
        )
        // Only reachable through `<root>/<name>`.
        fileSystem.addFile(Self.root + "/typescript/package.json", contents: Data(#"{"name":"typescript","bin":{"tsc":"./bin/tsc","tsserver":"./bin/tsserver"},"unknown":[1]}"#.utf8))
        fileSystem.addFile("/Users/tester/src/my-linked-cli/package.json", contents: Data(#"{"name":"my-linked-cli","bin":"./cli.js"}"#.utf8))
    }

    func tool(_ inventory: ProviderInventory, _ name: String) throws -> ProviderTool {
        try #require(inventory.tools.first { $0.packageName == name })
    }

    // MARK: Parsing

    @Test func decodesArrayAndObjectLists() throws {
        let dto = try JSONDecoder().decode(PNPMListDTO.self, from: try Fixture.data("PNPM/list-global.json"))
        #expect(dto.importers.count == 1)
        #expect(dto.importers.first?.path == Self.home + "/global/5")
        #expect(dto.dependencies.keys.sorted() == ["@anthropic-ai/claude-code", "my-linked-cli", "typescript"])
        #expect(dto.dependencies["typescript"]?.version == "5.9.2")

        let object = try JSONDecoder().decode(PNPMListDTO.self, from: Data(#"{"path":"/g","dependencies":{"a":{"version":"1.0.0"}}}"#.utf8))
        #expect(object.dependencies["a"]?.version == "1.0.0")

        let merged = try JSONDecoder().decode(PNPMListDTO.self, from: Data(#"[{"dependencies":{"a":{"version":"1.0.0"}}},42,{"dependencies":{"a":{"version":"2.0.0"},"b":{}}}]"#.utf8))
        #expect(merged.dependencies["a"]?.version == "1.0.0")
        #expect(merged.dependencies["b"] != nil)
    }

    @Test("Empty list shapes", arguments: [
        "[]",
        #"[{"path":"/Users/tester/Library/pnpm/global/5","private":false}]"#,
        #"[{"dependencies":{}}]"#,
        #"[{"dependencies":[]}]"#,
        #"[{"dependencies":{"weird":42,"nulled":null}}]"#,
        "{}",
    ])
    func emptyShapes(json: String) throws {
        let dto = try JSONDecoder().decode(PNPMListDTO.self, from: Data(json.utf8))
        #expect(dto.dependencies.isEmpty)
    }

    @Test("Local versions", arguments: [
        ("link:../src/tool", true), ("file:../tool.tgz", true), ("5.9.2", false), ("1.0.0-link", false),
    ])
    func localVersions(version: String, isLocal: Bool) {
        #expect(PNPMMapper.isLocal(version: version) == isLocal)
    }

    // MARK: Scan

    @Test func fastScan() async throws {
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.providerID == .pnpm)
        #expect(inventory.availability.version == "10.33.0")
        #expect(inventory.availability.executable == Self.pnpmPath)
        #expect(inventory.layout[.pnpmGlobalRoot] == Self.root)
        #expect(inventory.layout[.pnpmGlobalBin] == Self.home)
        #expect(inventory.tools.map(\.packageName) == ["@anthropic-ai/claude-code", "my-linked-cli", "typescript"])
        #expect(inventory.warnings.isEmpty)

        let claude = try tool(inventory, "@anthropic-ai/claude-code")
        #expect(claude.kind == .globalPackage)
        #expect(claude.installationID == "pnpm:@anthropic-ai/claude-code")
        #expect(claude.installedVersions == ["2.1.236"])
        #expect(claude.activeVersion == "2.1.236")
        #expect(claude.summary == "Claude Code")
        #expect(claude.homepage == "https://github.com/anthropics/claude-code")
        #expect(claude.installPrefix == Self.root + "/@anthropic-ai/claude-code")
        #expect(claude.executableNames == ["claude"])
        #expect(claude.executablePaths == [Self.home + "/claude"])
        #expect(claude.isDirect == true)
        #expect(claude.isPinned == false)
        #expect(claude.isOutdated == nil)
        #expect(claude.latestVersion == nil)

        let typescript = try tool(inventory, "typescript")
        #expect(typescript.executableNames == ["tsc", "tsserver"])
        #expect(typescript.executablePaths == [Self.home + "/tsc", Self.home + "/tsserver"])

        let linked = try tool(inventory, "my-linked-cli")
        #expect(linked.isPinned)
        #expect(linked.installedVersions.isEmpty)
        #expect(linked.activeVersion == nil)
        #expect(linked.executableNames == ["my-linked-cli"])

        #expect(Set(runner.arguments(of: "pnpm")) == [["--version"], ["root", "-g"], ["bin", "-g"], Self.listArguments])
        #expect(runner.commands.allSatisfy { $0.timeout == .seconds(30) && $0.environmentOverrides.isEmpty })
    }

    @Test func deepScanTreatsOutdatedExitOneAsSuccess() async throws {
        let inventory = try await provider.scan(context: context, depth: .deep)
        let claude = try tool(inventory, "@anthropic-ai/claude-code")
        #expect(claude.latestVersion == "2.1.270")
        #expect(claude.isOutdated == true)
        let typescript = try tool(inventory, "typescript")
        #expect(typescript.isOutdated == false)
        #expect(typescript.latestVersion == nil)
        let linked = try tool(inventory, "my-linked-cli")
        #expect(linked.isOutdated == nil)
        #expect(inventory.warnings.isEmpty)
        let outdated = try #require(runner.commands.first { $0.arguments == Self.outdatedArguments })
        #expect(outdated.timeout == .seconds(60))

        runner.stub("pnpm", Self.outdatedArguments, stdout: "")
        #expect(try await provider.scan(context: context, depth: .deep).tools.filter { !$0.isPinned }.allSatisfy { $0.isOutdated == false })
        runner.stub("pnpm", Self.outdatedArguments, stdout: "{}\n")
        #expect(try await provider.scan(context: context, depth: .deep).tools.filter { !$0.isPinned }.allSatisfy { $0.isOutdated == false })
    }

    @Test func brokenOutdatedBecomesWarning() async throws {
        runner.stub("pnpm", Self.outdatedArguments, stdout: " ERR_PNPM_META_FETCH_FAIL  GET https://registry.npmjs.org/typescript: request failed\n", exitCode: 1)
        let inventory = try await provider.scan(context: context, depth: .deep)
        #expect(inventory.tools.count == 3)
        #expect(inventory.tools.allSatisfy { $0.isOutdated == nil })
        #expect(inventory.warnings == ["pnpm outdated -g --format json failed (exit 1)"])

        runner.stub("pnpm", Self.outdatedArguments, result: CommandResult(exitCode: -1, termination: .timedOut))
        #expect(try await provider.scan(context: context, depth: .deep).warnings == ["pnpm outdated -g --format json failed (exit -1)"])
    }

    @Test func emptyGlobalDirectorySkipsOutdated() async throws {
        runner.stub("pnpm", Self.listArguments, stdout: #"[{"path":"/Users/tester/Library/pnpm/global/5","private":false}]"#)
        let inventory = try await provider.scan(context: context, depth: .deep)
        #expect(inventory.tools.isEmpty)
        #expect(inventory.warnings.isEmpty)
        #expect(!runner.commands.contains { $0.arguments.first == "outdated" })
    }

    @Test func missingGlobalBinIsTolerated() async throws {
        runner.stub("pnpm", ["bin", "-g"], stdout: "")
        var inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.layout[.pnpmGlobalBin] == nil)
        #expect(try tool(inventory, "typescript").executableNames == ["tsc", "tsserver"])
        #expect(try tool(inventory, "typescript").executablePaths.isEmpty)

        runner.stub("pnpm", ["bin", "-g"], stderr: " ERR_PNPM_NO_GLOBAL_BIN_DIR  Unable to find the global bin directory", exitCode: 1)
        inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.layout[.pnpmGlobalBin] == nil)
        #expect(inventory.tools.count == 3)
    }

    @Test func missingPackageJSONIsTolerated() async throws {
        let fileSystem = InMemoryFileSystem()
        let inventory = try await PNPMProvider(runner: runner, fileSystem: fileSystem).scan(context: context, depth: .fast)
        #expect(inventory.tools.count == 3)
        #expect(inventory.tools.allSatisfy { $0.executableNames.isEmpty && $0.executablePaths.isEmpty && $0.summary == nil })
    }

    @Test func listExitOneWithValidJSONStillParses() async throws {
        let json = try Fixture.string("PNPM/list-global.json")
        runner.stub("pnpm", Self.listArguments, stdout: json, stderr: "WARN  Issues with peer dependencies found\n", exitCode: 1)
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.tools.count == 3)
        #expect(inventory.warnings == ["WARN  Issues with peer dependencies found"])
    }

    @Test func malformedListFails() async throws {
        runner.stub("pnpm", Self.listArguments, stdout: "Legend: production dependency")
        await #expect(throws: ProviderError.parsingFailed(.pnpm, what: "pnpm list -g --depth=0 --json")) {
            try await provider.scan(context: context, depth: .fast)
        }
        runner.stub("pnpm", Self.listArguments, stderr: "boom", exitCode: 1)
        await #expect(throws: ProviderError.commandFailed(.pnpm, command: "pnpm list -g --depth=0 --json", exitCode: 1, stderr: "boom")) {
            try await provider.scan(context: context, depth: .fast)
        }
    }

    @Test func rootFailureThrows() async throws {
        runner.stub("pnpm", ["root", "-g"], stdout: "not a path")
        await #expect(throws: ProviderError.parsingFailed(.pnpm, what: "pnpm root -g")) {
            try await provider.scan(context: context, depth: .fast)
        }
        runner.stub("pnpm", ["root", "-g"], stderr: "boom", exitCode: 1)
        await #expect(throws: ProviderError.commandFailed(.pnpm, command: "pnpm root -g", exitCode: 1, stderr: "boom")) {
            try await provider.scan(context: context, depth: .fast)
        }
    }

    @Test func unavailableWithoutPNPM() async throws {
        #expect(await provider.availability(context: TestContext.empty).isAvailable == false)
        await #expect(throws: ProviderError.unavailable(.pnpm)) { try await provider.scan(context: TestContext.empty, depth: .fast) }
        #expect(throws: ProviderError.unavailable(.pnpm)) { try provider.cleanupPlan(context: TestContext.empty) }
        #expect(await provider.availability(context: context).version == "10.33.0")
    }

    // MARK: Plans

    @Test func plans() throws {
        let update = try provider.updatePlan(for: [Tools.pnpm("@anthropic-ai/claude-code"), Tools.pnpm("typescript"), Tools.pnpm("typescript")], context: context)
        #expect(update.kind == .update)
        #expect(update.providerID == .pnpm)
        #expect(update.requiresNetwork)
        #expect(update.commands.map(\.arguments) == [["add", "-g", "@anthropic-ai/claude-code@latest", "typescript@latest"]])
        #expect(update.commands.map(\.executable) == [Self.pnpmPath])
        #expect(update.targets.map(\.installationID) == [InstallationID("pnpm:@anthropic-ai/claude-code"), InstallationID("pnpm:typescript")])
        #expect(update.targets.map(\.toVersion) == ["5.9.3", "5.9.3"])
        #expect(update.steps.map(\.displayString) == ["pnpm add -g @anthropic-ai/claude-code@latest typescript@latest"])

        let uninstall = try provider.uninstallPlan(for: Tools.pnpm("typescript"), context: context)
        #expect(uninstall.kind == .uninstall)
        #expect(!uninstall.requiresNetwork)
        #expect(uninstall.commands.map(\.arguments) == [["remove", "-g", "typescript"]])

        let cleanup = try provider.cleanupPlan(context: context)
        #expect(cleanup.kind == .cleanup(.providerCache))
        #expect(!cleanup.requiresNetwork)
        #expect(cleanup.targets.isEmpty)
        #expect(cleanup.commands.map(\.arguments) == [["store", "prune"]])
        #expect(runner.invocations.isEmpty)

        #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [], context: context) }
        #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [Tools.npm("typescript")], context: context) }
        #expect(throws: ProviderError.unsupportedOperation) { try provider.uninstallPlan(for: Tools.uv("ruff"), context: context) }
    }

    @Test func linkedPackagesCannotBeUpdated() async throws {
        let inventory = try await provider.scan(context: context, depth: .fast)
        let linked = try tool(inventory, "my-linked-cli")
        #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [linked], context: context) }
        #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [try tool(inventory, "typescript"), linked], context: context) }
        #expect(try provider.uninstallPlan(for: linked, context: context).commands.map(\.arguments) == [["remove", "-g", "my-linked-cli"]])
    }

    @Test("Hostile names are rejected", arguments: hostilePackageNames)
    func hostileNames(name: String) throws {
        #expect(throws: ProviderError.invalidPackageName(name)) { try provider.updatePlan(for: [Tools.pnpm(name)], context: context) }
        #expect(throws: ProviderError.invalidPackageName(name)) { try provider.uninstallPlan(for: Tools.pnpm(name), context: context) }
        #expect(runner.invocations.isEmpty)
    }

    // MARK: Cleanup

    @Test func storeCandidate() async throws {
        runner.stub("pnpm", ["store", "path"], stdout: Self.store + "\n")
        runner.stub("du", ["-sk", Self.store], stdout: "4096\t\(Self.store)\n")
        fileSystem.addDirectory(Self.store)

        let candidates = try await provider.cleanupCandidates(context: context)
        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(candidate.id == "providerCache:pnpm")
        #expect(candidate.kind == .providerCache)
        #expect(candidate.risk == .low)
        #expect(candidate.paths == [Self.store])
        #expect(candidate.reclaimableBytes == 4_194_304)
        #expect(candidate.plan?.commands.map(\.arguments) == [["store", "prune"]])
        let du = try #require(runner.commands.first { $0.arguments.first == "-sk" })
        #expect(du.executable == "/usr/bin/du")
        #expect(du.timeout == .seconds(60))
        let storePath = try #require(runner.commands.first { $0.arguments == ["store", "path"] })
        #expect(storePath.timeout == .seconds(30))
        #expect(runner.commands.allSatisfy { !$0.arguments.contains("prune") })
    }

    @Test func storeCandidateEdgeCases() async throws {
        runner.stub("pnpm", ["store", "path"], stdout: Self.store + "\n")
        #expect(try await provider.cleanupCandidates(context: context).isEmpty, "No store directory")

        fileSystem.addDirectory(Self.store)
        let candidate = try #require(try await provider.cleanupCandidates(context: context).first)
        #expect(candidate.reclaimableBytes == nil, "du failure keeps the candidate")
        #expect(candidate.plan != nil)

        runner.stub("pnpm", ["store", "path"], stdout: "relative/store\n")
        await #expect(throws: ProviderError.parsingFailed(.pnpm, what: "pnpm store path")) {
            try await provider.cleanupCandidates(context: context)
        }
        runner.stub("pnpm", ["store", "path"], stderr: "boom", exitCode: 1)
        await #expect(throws: ProviderError.commandFailed(.pnpm, command: "pnpm store path", exitCode: 1, stderr: "boom")) {
            try await provider.cleanupCandidates(context: context)
        }
    }
}
