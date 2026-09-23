@testable import CLIStateProviders
import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing

@Suite("pipx provider")
struct PipxProviderTests {
    static let venvs = "/Users/tester/.local/pipx/venvs"

    let runner = StubCommandRunner()
    let fileSystem = InMemoryFileSystem()
    var provider: PipxProvider { PipxProvider(runner: runner, fileSystem: fileSystem) }
    let context = TestContext.pipx

    init() throws {
        try runner.stub("pipx", ["--version"], fixture: "Pipx/version.txt")
        try runner.stub("pipx", ["list", "--json"], fixture: "Pipx/list.json")
        runner.stub("pipx", ["environment", "--value", "PIPX_LOCAL_VENVS"], stdout: Self.venvs + "\n")
        runner.stub("pipx", ["environment", "--value", "PIPX_BIN_DIR"], stdout: "/Users/tester/.local/bin\n")
    }

    func tool(_ inventory: ProviderInventory, _ name: String) throws -> ProviderTool {
        try #require(inventory.tools.first { $0.packageName == name })
    }

    // MARK: Parsing

    @Test func decodesFixture() throws {
        let dto = try JSONDecoder().decode(PipxListDTO.self, from: try Fixture.data("Pipx/list.json"))
        #expect(dto.venvs.keys.sorted() == ["black", "jupyterlab", "poetry"])
        let black = try #require(dto.venvs["black"]?.mainPackage)
        #expect(black.package == "black")
        #expect(black.packageVersion == "24.10.0")
        #expect(black.apps == ["black", "blackd"])
        #expect(black.appPaths == [Self.venvs + "/black/bin/black", Self.venvs + "/black/bin/blackd"])
        #expect(black.pinned == false)
        let jupyter = try #require(dto.venvs["jupyterlab"]?.mainPackage)
        #expect(jupyter.includeDependencies)
        #expect(jupyter.appPathsOfDependencies == [Self.venvs + "/jupyterlab/bin/jupyter"])
    }

    @Test("Odd JSON shapes", arguments: [
        #"{"venvs":{}}"#,
        #"{"pipx_spec_version":"0.1","venvs":{}}"#,
        #"{"pipx_spec_version":"0.1"}"#,
        #"{"venvs":[]}"#,
        #"{"venvs":{"broken":42,"alsoBroken":null}}"#,
    ])
    func emptyShapes(json: String) throws {
        let dto = try JSONDecoder().decode(PipxListDTO.self, from: Data(json.utf8))
        #expect(dto.venvs.isEmpty)
    }

    @Test func pathValues() throws {
        let json = #"{"venvs":{"a":{"metadata":{"main_package":{"apps":["a",7,"b"],"app_paths":[{"__type__":"Path","__Path__":"/x/a/bin/a"},"/x/a/bin/b",{"__type__":"Path"},12,{"__Path__":"relative/c"}]}}}}}"#
        let dto = try JSONDecoder().decode(PipxListDTO.self, from: Data(json.utf8))
        let package = try #require(dto.venvs["a"]?.mainPackage)
        #expect(package.apps == ["a", "b"])
        #expect(package.appPaths == ["/x/a/bin/a", "/x/a/bin/b", "relative/c"])

        let tool = PipxMapper.tool(name: "a", venv: try #require(dto.venvs["a"]), venvsRoot: nil)
        #expect(tool.executablePaths == ["/x/a/bin/a", "/x/a/bin/b"], "Relative paths are dropped")
        #expect(tool.installPrefix == "/x/a", "Derived from the first app path without pipx environment")
    }

    @Test("Venv directory from an app path", arguments: [
        ("/Users/tester/.local/pipx/venvs/black/bin/black", "/Users/tester/.local/pipx/venvs/black"),
        ("/opt/pipx/venvs/black/scripts/black", nil),
        ("/bin/x", nil),
    ] as [(String, String?)])
    func venvDirectory(path: String, expected: String?) {
        #expect(PipxMapper.venvDirectory(fromAppPath: path) == expected)
    }

    // MARK: Scan

    @Test func fastScan() async throws {
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.providerID == .pipx)
        #expect(inventory.availability.version == "1.7.1")
        #expect(inventory.availability.executable == "/opt/homebrew/bin/pipx")
        #expect(inventory.layout[.pipxVenvs] == Self.venvs)
        #expect(inventory.layout[.pipxBinDir] == "/Users/tester/.local/bin")
        #expect(inventory.tools.map(\.packageName) == ["black", "jupyterlab", "poetry"])
        #expect(inventory.warnings.isEmpty)

        let black = try tool(inventory, "black")
        #expect(black.kind == .tool)
        #expect(black.installationID == "pipx:black")
        #expect(black.installedVersions == ["24.10.0"])
        #expect(black.activeVersion == "24.10.0")
        #expect(black.latestVersion == nil)
        #expect(black.isOutdated == nil)
        #expect(black.isPinned == false)
        #expect(black.isDirect == true)
        #expect(black.installPrefix == Self.venvs + "/black")
        #expect(black.executableNames == ["black", "blackd"])
        #expect(black.executablePaths == [Self.venvs + "/black/bin/black", Self.venvs + "/black/bin/blackd"])

        let jupyter = try tool(inventory, "jupyterlab")
        #expect(jupyter.isPinned)
        #expect(jupyter.executableNames == ["jupyter-lab", "jupyter"])
        #expect(jupyter.executablePaths == [Self.venvs + "/jupyterlab/bin/jupyter-lab", Self.venvs + "/jupyterlab/bin/jupyter"])

        let poetry = try tool(inventory, "poetry")
        #expect(poetry.activeVersion == "2.0.1")
        #expect(poetry.isPinned == false)

        #expect(Set(runner.arguments(of: "pipx")) == [
            ["--version"], ["list", "--json"],
            ["environment", "--value", "PIPX_LOCAL_VENVS"], ["environment", "--value", "PIPX_BIN_DIR"],
        ])
        #expect(runner.commands.allSatisfy { $0.timeout == .seconds(30) && $0.environmentOverrides.isEmpty })
    }

    @Test func deepScanMatchesFastScan() async throws {
        let deep = try await provider.scan(context: context, depth: .deep)
        #expect(deep.depth == .deep)
        #expect(deep.tools == (try await provider.scan(context: context, depth: .fast)).tools)
        #expect(runner.commands.allSatisfy { $0.timeout == .seconds(30) })
    }

    @Test func missingFields() async throws {
        runner.stub("pipx", ["list", "--json"], stdout: #"{"venvs":{"bare":{},"nometa":{"metadata":{}},"partial":{"metadata":{"main_package":{"package":"partial","package_version":"","apps":null}}}}}"#)
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.tools.map(\.packageName) == ["bare", "nometa", "partial"])
        for tool in inventory.tools {
            #expect(tool.installedVersions.isEmpty)
            #expect(tool.activeVersion == nil)
            #expect(tool.executableNames.isEmpty)
            #expect(tool.executablePaths.isEmpty)
            #expect(tool.installPrefix == "\(Self.venvs)/\(tool.packageName)")
        }
    }

    @Test func environmentFailuresAreTolerated() async throws {
        runner.stub("pipx", ["environment", "--value", "PIPX_LOCAL_VENVS"], stderr: "pipx: error: unrecognized arguments: --value", exitCode: 2)
        runner.stub("pipx", ["environment", "--value", "PIPX_BIN_DIR"], stdout: "not a path\n")
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.layout[.pipxVenvs] == nil)
        #expect(inventory.layout[.pipxBinDir] == nil)
        #expect(try tool(inventory, "black").installPrefix == Self.venvs + "/black")
        #expect(inventory.warnings == ["pipx: error: unrecognized arguments: --value"])
    }

    @Test func emptyInventoryNoticeIsNotAWarning() async throws {
        runner.stub("pipx", ["list", "--json"], stdout: #"{"pipx_spec_version":"0.1","venvs":{}}"#, stderr: "nothing has been installed with pipx 😴\n")
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.tools.isEmpty)
        #expect(inventory.warnings.isEmpty)
    }

    @Test func listProblemsExitOneWithValidJSONStillParses() async throws {
        let json = try Fixture.string("Pipx/list.json")
        runner.stub("pipx", ["list", "--json"], stdout: json, stderr: "⚠️ black has invalid interpreter /usr/bin/python3\n", exitCode: 1)
        let inventory = try await provider.scan(context: context, depth: .fast)
        #expect(inventory.tools.count == 3)
        #expect(inventory.warnings == ["⚠️ black has invalid interpreter /usr/bin/python3"])
    }

    @Test func malformedListFails() async throws {
        runner.stub("pipx", ["list", "--json"], stdout: "black 24.10.0")
        await #expect(throws: ProviderError.parsingFailed(.pipx, what: "pipx list --json")) {
            try await provider.scan(context: context, depth: .fast)
        }
        runner.stub("pipx", ["list", "--json"], stdout: "")
        await #expect(throws: ProviderError.parsingFailed(.pipx, what: "pipx list --json")) {
            try await provider.scan(context: context, depth: .fast)
        }
        runner.stub("pipx", ["list", "--json"], stderr: "boom", exitCode: 1)
        await #expect(throws: ProviderError.commandFailed(.pipx, command: "pipx list --json", exitCode: 1, stderr: "boom")) {
            try await provider.scan(context: context, depth: .fast)
        }
    }

    @Test func unavailableWithoutPipx() async throws {
        #expect(await provider.availability(context: TestContext.empty).isAvailable == false)
        await #expect(throws: ProviderError.unavailable(.pipx)) { try await provider.scan(context: TestContext.empty, depth: .fast) }
        #expect(throws: ProviderError.unavailable(.pipx)) { try provider.updatePlan(for: [Tools.pipx("black")], context: TestContext.empty) }
        #expect(await provider.availability(context: context).version == "1.7.1")
    }

    // MARK: Plans

    @Test func plans() throws {
        let update = try provider.updatePlan(for: [Tools.pipx("black"), Tools.pipx("poetry"), Tools.pipx("black")], context: context)
        #expect(update.kind == .update)
        #expect(update.providerID == .pipx)
        #expect(update.requiresNetwork)
        #expect(update.commands.map(\.arguments) == [["upgrade", "black"], ["upgrade", "poetry"]])
        #expect(update.commands.map(\.executable) == ["/opt/homebrew/bin/pipx", "/opt/homebrew/bin/pipx"])
        #expect(update.targets.map(\.installationID) == [InstallationID("pipx:black"), InstallationID("pipx:poetry")])
        #expect(update.steps.map(\.displayString) == ["pipx upgrade black", "pipx upgrade poetry"])

        let uninstall = try provider.uninstallPlan(for: Tools.pipx("black"), context: context)
        #expect(uninstall.kind == .uninstall)
        #expect(!uninstall.requiresNetwork)
        #expect(uninstall.commands.map(\.arguments) == [["uninstall", "black"]])
        #expect(runner.invocations.isEmpty)

        #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [], context: context) }
        #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [Tools.uv("ruff")], context: context) }
        #expect(throws: ProviderError.unsupportedOperation) { try provider.uninstallPlan(for: Tools.cargo("ripgrep"), context: context) }
    }

    @Test func pinnedVenvsCannotBeUpdated() throws {
        #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [Tools.pipx("jupyterlab", pinned: true)], context: context) }
        #expect(throws: ProviderError.unsupportedOperation) { try provider.updatePlan(for: [Tools.pipx("black"), Tools.pipx("jupyterlab", pinned: true)], context: context) }
        #expect(try provider.uninstallPlan(for: Tools.pipx("jupyterlab", pinned: true), context: context).commands.map(\.arguments) == [["uninstall", "jupyterlab"]])
    }

    @Test("Hostile names are rejected", arguments: hostilePackageNames)
    func hostileNames(name: String) throws {
        #expect(throws: ProviderError.invalidPackageName(name)) { try provider.updatePlan(for: [Tools.pipx(name)], context: context) }
        #expect(throws: ProviderError.invalidPackageName(name)) { try provider.uninstallPlan(for: Tools.pipx(name), context: context) }
        #expect(runner.invocations.isEmpty)
    }
}
