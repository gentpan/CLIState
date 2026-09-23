@testable import CLIStateProviders
import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing

@Suite("npm provider")
struct NPMProviderTests {
    static let nodeHome = "/Users/tester/.local/opt/node-v26.2.0-darwin-arm64"
    static let root = nodeHome + "/lib/node_modules"
    static let npmPath = "/Users/tester/.local/bin/npm"

    let runner = StubCommandRunner()
    let fileSystem = InMemoryFileSystem()
    var provider: NPMProvider { NPMProvider(runner: runner, fileSystem: fileSystem) }
    let context = TestContext.npm

    init() throws {
        runner.stub("npm", ["--version"], stdout: "12.0.1\n")
        try runner.stub("npm", ["root", "-g"], fixture: "NPM/root-global.txt")
        runner.stub("npm", ["prefix", "-g"], stdout: Self.nodeHome + "\n")
        try runner.stub("npm", ["list", "-g", "--depth=0", "--json"], fixture: "NPM/list-global.json")
        try runner.stub("npm", ["outdated", "-g", "--json"], fixture: "NPM/outdated-global.json", exitCode: 1)

        fileSystem.addSymlink(Self.npmPath, to: "/Users/tester/.local/opt/node-current/bin/npm")
        fileSystem.addSymlink("/Users/tester/.local/opt/node-current", to: "node-v26.2.0-darwin-arm64")
        fileSystem.addSymlink(Self.nodeHome + "/bin/npm", to: "../lib/node_modules/npm/bin/npm-cli.js")
        fileSystem.addExecutable(Self.root + "/npm/bin/npm-cli.js")
        packageJSON("npm", #"{"name":"npm","description":"a package manager for JavaScript","homepage":"https://docs.npmjs.com/","bin":{"npm":"bin/npm-cli.js","npx":"bin/npx-cli.js"}}"#)
        packageJSON("pnpm", #"{"name":"pnpm","description":"Fast, disk space efficient package manager","homepage":"https://pnpm.io","bin":{"pnpm":"bin/pnpm.cjs","pnpx":"bin/pnpx.cjs"},"engines":{"node":">=18"}}"#)
        packageJSON("@mimo-ai/cli", #"{"name":"@mimo-ai/cli","bin":{"mimo":"./bin/mimo"}}"#)
        // String form: exposed under the unscoped package name.
        packageJSON("@opencode-ai/cli", #"{"name":"@opencode-ai/cli","bin":"./bin/opencode2","homepage":{"unexpected":"object"}}"#)
    }

    func packageJSON(_ name: String, _ json: String) {
        fileSystem.addFile("\(Self.root)/\(name)/package.json", contents: Data(json.utf8))
    }

    func tool(_ inventory: ProviderInventory, _ name: String) throws -> ProviderTool {
        try #require(inventory.tools.first { $0.packageName == name })
    }

    // MARK: Scan

    @Test func fastScan() async throws {
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.tools.map(\.packageName) == ["@mimo-ai/cli", "@opencode-ai/cli", "npm", "pnpm"])
        #expect(inventory.availability.version == "12.0.1")
        #expect(inventory.layout[.npmGlobalRoot] == Self.root)
        #expect(inventory.layout[.npmGlobalBin] == Self.nodeHome + "/bin")

        let instance = try #require(inventory.instance)
        #expect(instance.id == ProviderInstanceID("npm@\(Self.root)"))
        #expect(instance.executable == Self.npmPath)
        #expect(instance.version == "12.0.1")
        #expect(instance.context == .standalone)

        let pnpm = try tool(inventory, "pnpm")
        #expect(pnpm.kind == .globalPackage)
        #expect(pnpm.instanceID == instance.id)
        #expect(pnpm.installationID == InstallationID("npm@\(Self.root):pnpm"))
        #expect(pnpm.installedVersions == ["10.33.0"])
        #expect(pnpm.activeVersion == "10.33.0")
        #expect(pnpm.executableNames == ["pnpm", "pnpx"])
        #expect(pnpm.summary == "Fast, disk space efficient package manager")
        #expect(pnpm.homepage == "https://pnpm.io")
        #expect(pnpm.installPrefix == Self.root + "/pnpm")
        #expect(pnpm.isDirect == true)
        #expect(pnpm.isOutdated == nil)
        #expect(pnpm.latestVersion == nil)

        #expect(try tool(inventory, "@mimo-ai/cli").executableNames == ["mimo"])
        let opencode = try tool(inventory, "@opencode-ai/cli")
        #expect(opencode.executableNames == ["cli"])
        #expect(opencode.homepage == nil)
        #expect(try tool(inventory, "npm").executableNames == ["npm", "npx"])

        #expect(Set(runner.arguments(of: "npm")) == [["--version"], ["root", "-g"], ["prefix", "-g"], ["list", "-g", "--depth=0", "--json"]])
        #expect(runner.commands.allSatisfy { $0.timeout == .seconds(30) && $0.environmentOverrides.isEmpty })
    }

    @Test func deepScanTreatsOutdatedExitOneAsSuccess() async throws {
        let inventory = try await provider.scan(context: context, depth: .deep)
        let mimo = try tool(inventory, "@mimo-ai/cli")
        #expect(mimo.latestVersion == "0.1.14")
        #expect(mimo.isOutdated == true)
        let opencode = try tool(inventory, "@opencode-ai/cli")
        #expect(opencode.latestVersion == "0.0.0-beta-17823")
        #expect(opencode.isOutdated == true)
        #expect(inventory.warnings.isEmpty)
        let outdated = try #require(runner.commands.first { $0.arguments.first == "outdated" })
        #expect(outdated.timeout == .seconds(60))
    }

    @Test func deepScanMarksUnlistedPackagesCurrent() async throws {
        runner.stub("npm", ["outdated", "-g", "--json"], stdout: #"{"pnpm":{"current":"10.33.0","wanted":"12.4.1","latest":"12.4.1"}}"#, exitCode: 1)
        let inventory = try await provider.scan(context: context, depth: .deep)
        #expect(try tool(inventory, "pnpm").isOutdated == true)
        #expect(try tool(inventory, "npm").isOutdated == false)
        #expect(try tool(inventory, "npm").latestVersion == nil)

        runner.stub("npm", ["outdated", "-g", "--json"], stdout: "{}\n")
        #expect(try await provider.scan(context: context, depth: .deep).tools.allSatisfy { $0.isOutdated == false })
    }

    @Test func brokenOutdatedBecomesWarning() async throws {
        runner.stub("npm", ["outdated", "-g", "--json"], stderr: "npm error code ENOTFOUND\nnpm error network request failed\n", exitCode: 1)
        let inventory = try await provider.scan(context: context, depth: .deep)
        #expect(inventory.tools.count == 4)
        #expect(inventory.tools.allSatisfy { $0.isOutdated == nil })
        #expect(inventory.warnings.contains("npm error code ENOTFOUND"))
        #expect(inventory.warnings.contains { $0.contains("npm outdated -g --json failed (exit 1)") })
    }

    @Test func listExitOneWithValidJSONStillParses() async throws {
        let json = try Fixture.string("NPM/list-global.json")
        runner.stub("npm", ["list", "-g", "--depth=0", "--json"], stdout: json, stderr: "npm warn extraneous: foo\n", exitCode: 1)
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.tools.count == 4)
        #expect(inventory.warnings == ["npm warn extraneous: foo"])
    }

    @Test func malformedListFails() async throws {
        runner.stub("npm", ["list", "-g", "--depth=0", "--json"], stdout: "npm ERR! something")
        await #expect(throws: ProviderError.parsingFailed(.npm, what: "npm list -g --depth=0 --json")) {
            try await provider.scan(context: context, depth: .fast)
        }
        runner.stub("npm", ["list", "-g", "--depth=0", "--json"], stderr: "boom", exitCode: 2)
        await #expect(throws: ProviderError.commandFailed(.npm, command: "npm list -g --depth=0 --json", exitCode: 2, stderr: "boom")) {
            try await provider.scan(context: context, depth: .fast)
        }
    }

    @Test func emptyAndOddLists() async throws {
        runner.stub("npm", ["list", "-g", "--depth=0", "--json"], stdout: "{}")
        #expect(try await provider.scan(context: context, depth: .fast).tools.isEmpty)

        runner.stub("npm", ["list", "-g", "--depth=0", "--json"], stdout: #"{"dependencies":{"ok":{"version":"1.0.0"},"gone":{"missing":true},"weird":42,"noversion":{}},"problems":["x"]}"#)
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.tools.map(\.packageName) == ["noversion", "ok"])
        let ok = try tool(inventory, "ok")
        #expect(ok.executableNames.isEmpty, "Missing package.json is tolerated")
        #expect(try tool(inventory, "noversion").installedVersions.isEmpty)
    }

    @Test func rootFailureThrows() async throws {
        runner.stub("npm", ["root", "-g"], stdout: "not a path")
        await #expect(throws: ProviderError.parsingFailed(.npm, what: "npm root -g")) {
            try await provider.scan(context: context, depth: .fast)
        }
    }

    @Test func unavailableWithoutNPM() async throws {
        let availability = await provider.availability(context: TestContext.empty)
        #expect(!availability.isAvailable)
        await #expect(throws: ProviderError.unavailable(.npm)) { try await provider.scan(context: TestContext.empty, depth: .fast) }
        #expect(await provider.availability(context: context).version == "12.0.1")
    }

    @Test("bin field", arguments: [
        ("@scope/tool", NPMPackageJSONDTO.Bin?.some(.single("cli.js")), ["tool"]),
        ("plain", .some(.single("./index.js")), ["plain"]),
        ("multi", .some(.named(["b": "b.js", "a": "a.js"])), ["a", "b"]),
        ("none", nil, []),
    ])
    func binField(name: String, bin: NPMPackageJSONDTO.Bin?, expected: [String]) {
        #expect(NPMMapper.executableNames(packageName: name, bin: bin) == expected)
    }

    // MARK: Context inference

    @Test("Environment context from npm realpath", arguments: [
        ("/Users/tester/.nvm/versions/node/v22.11.0/lib/node_modules/npm/bin/npm-cli.js", EnvironmentContext.nvm(version: "22.11.0")),
        ("/Users/tester/.local/share/fnm/node-versions/v20.1.0/installation/lib/node_modules/npm/bin/npm-cli.js", .fnm(version: "20.1.0")),
        ("/Users/tester/.volta/tools/image/npm/10.0.0/bin/npm-cli.js", .volta),
        ("/Users/tester/.local/share/mise/installs/node/24.0.0/lib/node_modules/npm/bin/npm-cli.js", .mise(version: "24.0.0")),
        ("/Users/tester/.asdf/installs/nodejs/18.20.0/lib/node_modules/npm/bin/npm-cli.js", .asdf(version: "18.20.0")),
        ("/opt/homebrew/Cellar/node/26.0.0/lib/node_modules/npm/bin/npm-cli.js", .homebrew),
        ("/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", .homebrew),
        ("/Users/tester/.local/opt/node-v26.2.0-darwin-arm64/lib/node_modules/npm/bin/npm-cli.js", .standalone),
        ("/usr/local/lib/node_modules/npm/bin/npm-cli.js", .standalone),
    ])
    func environmentContext(path: String, expected: EnvironmentContext) {
        let fs = InMemoryFileSystem()
        fs.addDirectory("/opt/homebrew/Cellar/node/26.0.0")
        let prefix = path.hasPrefix("/usr/local") ? "/usr/local" : "/opt/homebrew"
        #expect(NPMMapper.environmentContext(npmRealPath: path, homebrewPrefix: prefix, fileSystem: fs) == expected)
    }

    @Test func homebrewNodeModulesWithoutNodeKegIsStandalone() {
        let path = "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js"
        #expect(NPMMapper.environmentContext(npmRealPath: path, homebrewPrefix: "/opt/homebrew", fileSystem: InMemoryFileSystem()) == .standalone)
        #expect(NPMMapper.environmentContext(npmRealPath: path, homebrewPrefix: nil, fileSystem: InMemoryFileSystem()) == .standalone)
    }

    @Test func scanInfersHomebrewInstance() async throws {
        let context = TestContext.make(["npm": "/opt/homebrew/bin/npm", "brew": "/opt/homebrew/bin/brew"])
        fileSystem.addSymlink("/opt/homebrew/bin/npm", to: "../lib/node_modules/npm/bin/npm-cli.js")
        fileSystem.addExecutable("/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js")
        fileSystem.addDirectory("/opt/homebrew/Cellar/node/26.0.0")
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.instance?.context == .homebrew)
    }

    // MARK: Plans

    @Test func plans() throws {
        let update = try provider.updatePlan(for: [Tools.npm("@mimo-ai/cli"), Tools.npm("pnpm"), Tools.npm("pnpm")], context: context)
        #expect(update.kind == .update)
        #expect(update.requiresNetwork)
        #expect(update.commands.map(\.arguments) == [["install", "-g", "@mimo-ai/cli@latest", "pnpm@latest"]])
        #expect(update.commands.map(\.executable) == [Self.npmPath])
        #expect(update.targets.map(\.installationID) == [InstallationID("npm@\(Self.root):@mimo-ai/cli"), InstallationID("npm@\(Self.root):pnpm")])
        #expect(update.steps.map(\.displayString) == ["npm install -g @mimo-ai/cli@latest pnpm@latest"])

        let uninstall = try provider.uninstallPlan(for: Tools.npm("@opencode-ai/cli"), context: context)
        #expect(uninstall.kind == .uninstall)
        #expect(!uninstall.requiresNetwork)
        #expect(uninstall.commands.map(\.arguments) == [["uninstall", "-g", "@opencode-ai/cli"]])

        let cleanup = try provider.cleanupPlan(context: context)
        #expect(cleanup.kind == .cleanup(.providerCache))
        #expect(cleanup.commands.map(\.arguments) == [["cache", "clean", "--force"]])
        #expect(runner.invocations.isEmpty)

        #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [Tools.formula("php")], context: context) }
        #expect(throws: ProviderError.unavailable(.npm)) { try provider.cleanupPlan(context: TestContext.empty) }
    }

    @Test("Hostile names are rejected", arguments: hostilePackageNames)
    func hostileNames(name: String) throws {
        #expect(throws: ProviderError.invalidPackageName(name)) { try provider.updatePlan(for: [Tools.npm(name)], context: context) }
        #expect(throws: ProviderError.invalidPackageName(name)) { try provider.uninstallPlan(for: Tools.npm(name), context: context) }
        #expect(runner.invocations.isEmpty)
    }

    // MARK: Cleanup

    @Test func cacheCandidate() async throws {
        runner.stub("npm", ["config", "get", "cache"], stdout: "/Users/tester/.npm\n")
        runner.stub("du", ["-sk", "/Users/tester/.npm/_cacache"], stdout: "2048\t/Users/tester/.npm/_cacache\n")
        fileSystem.addDirectory("/Users/tester/.npm/_cacache")

        let candidates = try await provider.cleanupCandidates(context: context)
        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(candidate.id == "providerCache:npm")
        #expect(candidate.kind == .providerCache)
        #expect(candidate.risk == .low)
        #expect(candidate.paths == ["/Users/tester/.npm/_cacache"])
        #expect(candidate.reclaimableBytes == 2_097_152)
        #expect(candidate.plan?.commands.map(\.arguments) == [["cache", "clean", "--force"]])
        let du = try #require(runner.commands.first { $0.arguments.first == "-sk" })
        #expect(du.executable == "/usr/bin/du")
    }

    @Test func noCacheDirectoryMeansNoCandidate() async throws {
        runner.stub("npm", ["config", "get", "cache"], stdout: "/Users/tester/.npm\n")
        #expect(try await provider.cleanupCandidates(context: context).isEmpty)
    }

    @Test func sizeIsOptionalWhenDuFails() async throws {
        runner.stub("npm", ["config", "get", "cache"], stdout: "/Users/tester/.npm\n")
        fileSystem.addDirectory("/Users/tester/.npm/_cacache")
        let candidate = try #require(try await provider.cleanupCandidates(context: context).first)
        #expect(candidate.reclaimableBytes == nil)
        #expect(candidate.plan != nil)
    }
}
