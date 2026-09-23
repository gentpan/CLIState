import CLIStateDomain
@testable import CLIStateEngine
import CLIStateTestSupport
import Foundation
import Testing

@Suite("Script and package recognition")
struct ScriptAndPackageRecognitionTests {
    // MARK: Shebang parsing

    @Test func parsesInterpreterLines() {
        let brewPython = "/opt/homebrew/opt/python@3.14/bin/python3.14"
        #expect(Shebang.parse(Data("#!\(brewPython)\nimport sys\n".utf8)) == Shebang(interpreter: brewPython))
        #expect(Shebang.parse(Data("#!\(brewPython)\r\nimport sys\r\n".utf8)) == Shebang(interpreter: brewPython))
        #expect(Shebang.parse(Data("#! /bin/sh -e\n".utf8)) == Shebang(interpreter: "/bin/sh", argument: "-e"))
        #expect(Shebang.parse(Data("#!/usr/bin/env python3\n".utf8)) == Shebang(interpreter: "/usr/bin/env", argument: "python3"))
        #expect(Shebang.parse(Data("#!/usr/bin/env -S python3 -u\n".utf8)) == Shebang(interpreter: "/usr/bin/env", argument: "-S python3 -u"))
        // A file that is only the interpreter line.
        #expect(Shebang.parse(Data("#!/bin/sh".utf8)) == Shebang(interpreter: "/bin/sh"))
    }

    @Test func rejectsFilesWithoutAUsableInterpreterLine() {
        #expect(Shebang.parse(Data()) == nil)
        #expect(Shebang.parse(Data("import sys\n".utf8)) == nil)
        #expect(Shebang.parse(Data(MachOHeader.arm64)) == nil)
        #expect(Shebang.parse(Data("#!python3\n".utf8)) == nil)
        #expect(Shebang.parse(Data("#!\n".utf8)) == nil)
        #expect(Shebang.parse(Data([0x23, 0x21, 0x2f, 0xff, 0xfe, 0x0a])) == nil)
        // Cut off by the read limit: the interpreter name may be incomplete.
        #expect(Shebang.parse(Data(("#!/" + String(repeating: "a", count: Shebang.maxLength)).utf8)) == nil)
    }

    @Test func readsOnlyABoundedPrefixOfRegularFiles() {
        let fs = RecordingFileSystem()
        fs.base.addExecutable("/opt/homebrew/bin/idna", contents: "#!/opt/homebrew/opt/python@3.14/bin/python3.14\n" + String(repeating: "#\n", count: 4096))
        fs.base.addDirectory("/opt/homebrew/bin/dir")

        #expect(Shebang.read(atPath: "/opt/homebrew/bin/idna", fileSystem: fs)?.interpreter == "/opt/homebrew/opt/python@3.14/bin/python3.14")
        #expect(Shebang.read(atPath: "/opt/homebrew/bin/dir", fileSystem: fs) == nil)
        #expect(Shebang.read(atPath: "/opt/homebrew/bin/missing", fileSystem: fs) == nil)
        #expect(fs.reads == [RecordingFileSystem.Read(path: "/opt/homebrew/bin/idna", maxBytes: Shebang.maxLength)])
    }

    // MARK: Scripts run by a Homebrew keg's interpreter

    /// Real shape (2026-09-13): `pip` wrote `normalizer`, `wsdump`, `idna` and `cffi-gen-src`
    /// into `/opt/homebrew/bin` as plain files whose shebang is Homebrew's python@3.14.
    @Test func pipScriptsInHomebrewPythonAreReadOnlyHomebrewTools() async throws {
        let scenario = EngineScenario()
        let keg = "/opt/homebrew/Cellar/python@3.14/3.14.7"
        let interpreter = "/opt/homebrew/opt/python@3.14/bin/python3.14"
        scenario.binary("\(keg)/Frameworks/Python.framework/Versions/3.14/bin/python3.14", header: MachOHeader.arm64)
        scenario.link("\(keg)/bin/python3.14", to: "\(keg)/Frameworks/Python.framework/Versions/3.14/bin/python3.14")
        scenario.link("/opt/homebrew/opt/python@3.14", to: keg)
        scenario.link("/opt/homebrew/bin/python3", to: "\(keg)/bin/python3.14")

        scenario.executable("/opt/homebrew/bin/normalizer", contents: "#!\(interpreter)\nimport sys\nfrom charset_normalizer.cli import cli_detect\n")
        scenario.executable("/opt/homebrew/bin/wsdump", contents: "#!\(interpreter)\r\nimport sys\r\n")
        // A script sharing a formula's name must not join that formula's tool.
        scenario.executable("/opt/homebrew/bin/cffi", contents: "#!\(interpreter)\nimport sys\n")

        // Not Homebrew's environment: PATH lookup, a venv linking to the keg, a removed
        // Python, no shebang, a binary.
        scenario.executable("/usr/local/bin/envpy", contents: "#!/usr/bin/env python3\nimport sys\n")
        scenario.link("\(home)/proj/.venv/bin/python", to: interpreter)
        scenario.executable("\(home)/.local/bin/venvtool", contents: "#!\(home)/proj/.venv/bin/python\nimport sys\n")
        scenario.executable("\(home)/.local/bin/stale", contents: "#!/opt/homebrew/opt/python@3.13/bin/python3.13\nimport sys\n")
        scenario.executable("\(home)/.local/bin/plain", contents: "echo hello\n")
        scenario.binary("\(home)/.local/bin/machotool", header: MachOHeader.arm64)

        let inventory = homebrewInventory([
            formula("python@3.14", "3.14.7", direct: false, executables: ["python3"]),
            formula("cffi", "2.1.1", direct: false),
        ])
        let snapshot = await scenario.build(inventories: [inventory])

        let normalizer = try #require(snapshot.tool("homebrew.python@3.14:normalizer"))
        #expect(normalizer.identity == ToolIdentity(name: "normalizer", displayName: "normalizer", category: .developerTool))
        let installation = try #require(normalizer.installations.first)
        #expect(normalizer.installations.count == 1)
        #expect(installation.id == "path:/opt/homebrew/bin/normalizer")
        #expect(installation.ownership == Ownership(provider: .homebrew, confidence: .probable, evidence: [.knownLayout(interpreter)]))
        #expect(installation.linkState == .active)
        #expect(installation.version == nil)
        #expect(installation.capabilities == .none, "not a brew package: no update, uninstall or trash")

        #expect(snapshot.tool("homebrew.python@3.14:wsdump")?.installations.first?.ownership.provider == .homebrew, "CRLF line endings")
        #expect(snapshot.tool("homebrew.python@3.14:cffi")?.installations.map(\.id) == ["path:/opt/homebrew/bin/cffi"])
        #expect(snapshot.tool("homebrew.cffi")?.installations.map(\.id) == ["homebrew:cffi"])

        let python = try #require(snapshot.tool("python"))
        #expect(python.installations.map(\.id) == ["homebrew:python@3.14"])
        #expect(python.installations.flatMap(\.executables).map(\.name) == ["python3"])

        let unrecognized = snapshot.tools.filter { $0.identity.category == .unrecognized }
        #expect(Set(unrecognized.map(\.identity.name)) == ["envpy", "venvtool", "stale", "plain", "machotool"])
        #expect(unrecognized.allSatisfy { $0.installations.first?.ownership.provider == .standalone })
        #expect(scenario.runner.invocations.isEmpty, "scripts are read, never run")
    }

    // MARK: uv-managed Python

    @Test func parsesUVPythonDirectoryNames() {
        let cpython = UVPythonDirectory(name: "cpython-3.12.13-macos-aarch64-none")
        #expect(cpython?.implementation == "cpython")
        #expect(cpython?.version == "3.12.13")
        #expect(cpython?.isCPython == true)
        #expect(UVPythonDirectory(name: "cpython-3.13.1+freethreaded-macos-aarch64-none")?.version == "3.13.1")
        #expect(UVPythonDirectory(name: "cpython-3.14.0a3-macos-x86_64-none")?.version == "3.14.0a3")
        let pypy = UVPythonDirectory(name: "pypy-3.10.14-macos-aarch64-none")
        #expect(pypy?.version == "3.10.14")
        #expect(pypy?.isCPython == false)
        #expect(UVPythonDirectory(name: ".temp") == nil)
        #expect(UVPythonDirectory(name: ".lock") == nil)
        #expect(UVPythonDirectory(name: "cpython-macos-aarch64-none") == nil)
        #expect(UVPythonDirectory(name: "cpython-latest-macos-aarch64-none-x") == nil)
        #expect(UVPythonDirectory(name: "cpython-3-macos-aarch64-none") == nil)
    }

    /// Real shape: `~/.local/bin/python3.12 → …/uv/python/cpython-3.12-macos-aarch64-none/bin/python3.12`,
    /// the minor-version directory itself linking to `cpython-3.12.13-macos-aarch64-none`.
    @Test func uvManagedPythonsAreInstallationsOfPython() async throws {
        let scenario = EngineScenario()
        let root = "\(home)/.local/share/uv/python"
        installUVPython(scenario, root: root, versions: ["3.10.20", "3.12.13", "3.13.13"])
        scenario.fs.addFile("\(root)/.lock")
        scenario.fs.addDirectory("\(root)/.temp")
        scenario.link("\(home)/.local/bin/python3.12", to: "\(root)/cpython-3.12-macos-aarch64-none/bin/python3.12")

        let snapshot = await scenario.build()
        let python = try #require(snapshot.tool("python"))
        #expect(Set(python.installations.map(\.id)) == [
            "path:\(home)/.local/bin/python3.12",
            "path:\(root)/cpython-3.10.20-macos-aarch64-none/bin/python",
            "path:\(root)/cpython-3.13.13-macos-aarch64-none/bin/python",
        ])

        let onPath = try #require(python.installation("path:\(home)/.local/bin/python3.12"))
        #expect(onPath.ownership == Ownership(provider: .uv, confidence: .probable, evidence: [.knownLayout(root)]))
        #expect(onPath.version?.value.rawValue == "3.12.13")
        #expect(onPath.version?.source == .path)
        #expect(onPath.installPrefix == "\(root)/cpython-3.12.13-macos-aarch64-none")
        #expect(onPath.linkState == .active)
        #expect(onPath.capabilities == .none)
        #expect(python.activeInstallationID == onPath.id)

        let older = try #require(python.installation("path:\(root)/cpython-3.10.20-macos-aarch64-none/bin/python"))
        #expect(older.linkState == .notOnPath)
        #expect(older.version?.value.rawValue == "3.10.20")
        #expect(python.installations.compactMap { $0.version?.value.rawValue }.sorted() == ["3.10.20", "3.12.13", "3.13.13"])

        #expect(!snapshot.tools.contains { $0.identity.category == .unrecognized })
        #expect(scenario.runner.invocations.isEmpty, "the directory name already carries the version")
        #expect(snapshot.cleanupCandidates.isEmpty, "uv projects use these without PATH")
    }

    @Test func uvPythonInstallDirIsRespected() async throws {
        let scenario = EngineScenario()
        scenario.variables["UV_PYTHON_INSTALL_DIR"] = "~/.pythons"
        installUVPython(scenario, root: "\(home)/.pythons", versions: ["3.11.9"])
        scenario.link("\(home)/.local/bin/python3.11", to: "\(home)/.pythons/cpython-3.11.9-macos-aarch64-none/bin/python3.11")

        let snapshot = await scenario.build()
        let installation = try #require(snapshot.tool("python")?.installation("path:\(home)/.local/bin/python3.11"))
        #expect(installation.ownership.provider == .uv)
        #expect(installation.ownership.evidence == [.knownLayout("\(home)/.pythons")])
        #expect(installation.version?.value.rawValue == "3.11.9")

        // Other implementations are uv's too, but not the registry's CPython.
        let context = AttributionContext(homeDirectory: home, variables: [:], inventories: [])
        let pypy = AttributionEngine(fileSystem: scenario.fs, context: context).attribute(
            name: "pypy3", path: "\(home)/.local/bin/pypy3", resolvedPath: "\(home)/.local/share/uv/python/pypy-3.10.14-macos-aarch64-none/bin/pypy3.10"
        )
        #expect(pypy.ownership.provider == .uv)
        #expect(pypy.pathVersion == "3.10.14")
        #expect(pypy.layoutDefinitionID == nil)

        let engine = AttributionEngine(fileSystem: scenario.fs, context: context)
        let bin = "\(home)/.local/share/uv/python/cpython-3.12.13-macos-aarch64-none/bin"
        #expect(engine.attribute(name: "python3.12", path: "\(home)/.local/bin/python3.12", resolvedPath: "\(bin)/python3.12").layoutDefinitionID == "python")
        #expect(engine.attribute(name: "python", path: "\(bin)/python", resolvedPath: "\(bin)/python3.12").layoutDefinitionID == "python")
        for helper in ["pip3.12", "idle3", "python3.12-config"] {
            let attribution = engine.attribute(name: helper, path: "\(bin)/\(helper)", resolvedPath: nil)
            #expect(attribution.ownership.provider == .uv, "\(helper)")
            #expect(attribution.layoutDefinitionID == nil, "\(helper)")
        }
    }

    private func installUVPython(_ scenario: EngineScenario, root: String, versions: [String]) {
        for version in versions {
            let minor = version.split(separator: ".").prefix(2).joined(separator: ".")
            let directory = "\(root)/cpython-\(version)-macos-aarch64-none"
            scenario.binary("\(directory)/bin/python\(minor)", header: MachOHeader.arm64)
            scenario.link("\(directory)/bin/python3", to: "\(directory)/bin/python\(minor)")
            scenario.link("\(directory)/bin/python", to: "\(directory)/bin/python\(minor)")
            scenario.link("\(root)/cpython-\(minor)-macos-aarch64-none", to: directory)
        }
    }

    // MARK: Stable ids for unrecognized tools

    /// grok replaces `~/.grok/bin/grok → ../downloads/grok-<version>-macos-aarch64` on every upgrade.
    @Test func unknownToolIDSurvivesAnUpgrade() async throws {
        let scenario = EngineScenario()
        func install(_ version: String) {
            let download = "\(home)/.grok/downloads/grok-\(version)-macos-aarch64"
            scenario.binary(download, header: MachOHeader.arm64)
            scenario.link("\(home)/.grok/bin/grok", to: "../downloads/grok-\(version)-macos-aarch64")
            scenario.link("\(home)/.local/bin/grok", to: "\(home)/.grok/bin/grok")
        }
        install("1.0.25")
        let before = await scenario.build()
        scenario.fs.remove("\(home)/.grok/downloads/grok-1.0.25-macos-aarch64")
        install("1.0.26")
        let after = await scenario.build(previous: before)

        let old = try #require(before.tools.first { $0.identity.name == "grok" })
        let new = try #require(after.tools.first { $0.identity.name == "grok" })
        #expect(old.installations.first?.executables.first?.resolvedPath == "\(home)/.grok/downloads/grok-1.0.25-macos-aarch64")
        #expect(new.installations.first?.executables.first?.resolvedPath == "\(home)/.grok/downloads/grok-1.0.26-macos-aarch64")
        #expect(new.id == old.id)
        #expect(new.id == MergeEngine.unknownToolID(name: "grok", location: "\(home)/.grok/bin/grok"))
        #expect(new.installations.map(\.id) == old.installations.map(\.id))
        #expect(new.installations.first?.executables.map(\.path) == ["\(home)/.grok/bin/grok", "\(home)/.local/bin/grok"])
        #expect(after.tools.filter { $0.identity.name == "grok" }.count == 1)
    }

    // MARK: Same package from several npm-registry providers

    /// Real shape: `@opencode-ai/cli` from npm (not on PATH) and from `bun add -g` (exposing `opencode2`).
    @Test func samePackageFromNPMAndBunIsOneToolWithTwoInstallations() async throws {
        let scenario = EngineScenario()
        let root = "\(home)/.local/opt/node-v26.2.0-darwin-arm64/lib/node_modules"
        let bunPackage = "\(home)/.bun/install/global/node_modules/@opencode-ai/cli"
        scenario.executable("\(bunPackage)/bin/opencode2")
        scenario.link("\(home)/.bun/bin/opencode2", to: "\(bunPackage)/bin/opencode2")
        let inventory = npmInventory(root: root, [npmPackage("@opencode-ai/cli", "0.0.0-next-15329", executables: ["opencode2"])])

        let first = await scenario.build(inventories: [inventory])
        #expect(first.tools.filter { $0.identity.name == "@opencode-ai/cli" }.count == 1)
        let tool = try #require(first.tool("npm.@opencode-ai/cli"))
        #expect(tool.identity.displayName == "@opencode-ai/cli")
        #expect(tool.installations.map(\.id) == ["bun:@opencode-ai/cli", "npm@\(root):@opencode-ai/cli"])
        #expect(tool.activeInstallationID == "bun:@opencode-ai/cli")
        #expect(tool.resolution?.chain.map(\.path) == ["\(home)/.bun/bin/opencode2"])

        let bun = try #require(tool.installation("bun:@opencode-ai/cli"))
        #expect(bun.ownership.provider == .bun)
        #expect(bun.linkState == .active)
        #expect(bun.capabilities == .none)
        let npm = try #require(tool.installation("npm@\(root):@opencode-ai/cli"))
        #expect(npm.ownership.provider == .npm)
        #expect(npm.ownership.confidence == .confirmed)
        #expect(npm.linkState == .notOnPath)
        #expect(npm.version?.value.rawValue == "0.0.0-next-15329")
        #expect(npm.capabilities.canUpdate && npm.capabilities.canUninstall)
        #expect(first.issues(for: tool.id).isEmpty, "only one copy is on PATH")

        let second = await scenario.build(inventories: [inventory], previous: first)
        #expect(second.tools.map(\.id) == first.tools.map(\.id))
        #expect(second.tool(tool.id)?.installations.map(\.id) == tool.installations.map(\.id))
    }

    @Test func packageToolIDsShareOnlyTheNPMRegistryNamespace() {
        #expect(MergeEngine.packageToolID(provider: .npm, package: "@opencode-ai/cli") == "npm.@opencode-ai/cli")
        #expect(MergeEngine.packageToolID(provider: .bun, package: "@opencode-ai/cli") == "npm.@opencode-ai/cli")
        #expect(MergeEngine.packageToolID(provider: .pnpm, package: "typescript") == "npm.typescript")
        #expect(MergeEngine.packageToolID(provider: .homebrew, package: "typescript") == "homebrew.typescript")
        #expect(MergeEngine.packageToolID(provider: .uv, package: "ruff") == "uv.ruff")

        let registry = ToolRegistry.standard
        #expect(registry.definition(forPackage: "opencode-ai", provider: .bun)?.id == "opencode")
        #expect(registry.definition(forPackage: "@anthropic-ai/claude-code", provider: .pnpm)?.id == "claude-code")
        #expect(registry.definition(forPackage: "opencode-ai", provider: .uv) == nil)
    }
}

/// Records every `readData` call so tests can check reads stay bounded.
final class RecordingFileSystem: FileSystem, @unchecked Sendable {
    struct Read: Hashable {
        var path: String
        var maxBytes: Int?
    }

    let base = InMemoryFileSystem(home: home)
    private let lock = NSLock()
    private var recorded: [Read] = []

    var reads: [Read] { lock.withLock { recorded } }
    var homeDirectory: String { base.homeDirectory }

    func attributes(atPath path: String) -> FileAttributes? { base.attributes(atPath: path) }
    func contentsOfDirectory(atPath path: String) throws -> [String] { try base.contentsOfDirectory(atPath: path) }
    func destinationOfSymbolicLink(atPath path: String) throws -> String { try base.destinationOfSymbolicLink(atPath: path) }
    func resolvingSymlinks(atPath path: String) -> String? { base.resolvingSymlinks(atPath: path) }
    func isExecutableFile(atPath path: String) -> Bool { base.isExecutableFile(atPath: path) }
    func isWritable(atPath path: String) -> Bool { base.isWritable(atPath: path) }

    func readData(atPath path: String, maxBytes: Int?) throws -> Data {
        lock.withLock { recorded.append(Read(path: path, maxBytes: maxBytes)) }
        return try base.readData(atPath: path, maxBytes: maxBytes)
    }
}
