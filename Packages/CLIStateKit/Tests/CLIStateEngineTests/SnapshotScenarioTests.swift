import CLIStateDomain
@testable import CLIStateEngine
import CLIStateTestSupport
import Foundation
import Testing

@Suite("Snapshot scenarios")
struct SnapshotScenarioTests {
    // MARK: node — standalone shadows Homebrew (F8, §19)

    @Test func standaloneNodeShadowsHomebrewNode() async throws {
        let scenario = EngineScenario()
        scenario.binary("\(home)/.local/opt/node-v26.2.0-darwin-arm64/bin/node", header: MachOHeader.arm64)
        scenario.link("\(home)/.local/opt/node-current", to: "node-v26.2.0-darwin-arm64")
        scenario.link("\(home)/.local/bin/node", to: "\(home)/.local/opt/node-current/bin/node")
        scenario.binary("/opt/homebrew/Cellar/node/26.7.0/bin/node", header: MachOHeader.arm64)
        scenario.link("/opt/homebrew/bin/node", to: "../Cellar/node/26.7.0/bin/node")
        scenario.runner.stub("node", ["--version"], stdout: "v26.2.0\n")

        let snapshot = await scenario.build(inventories: [homebrewInventory([formula("node", "26.7.0", latest: "26.7.0", executables: ["node"])])])
        let node = try #require(snapshot.tool("node"))

        #expect(node.installations.count == 2)
        #expect(node.identity.category == .runtime)
        #expect(node.activeInstallationID == "path:\(home)/.local/bin/node")

        let standalone = try #require(node.installation("path:\(home)/.local/bin/node"))
        #expect(standalone.ownership.provider == .standalone)
        #expect(standalone.ownership.confidence == .unknown)
        #expect(standalone.linkState == .active)
        #expect(standalone.version?.value.rawValue == "26.2.0")
        #expect(standalone.version?.source == .executable("node --version"))
        #expect(standalone.executables.first?.pathPriority == 10)
        #expect(standalone.executables.first?.architecture == .arm64)
        #expect(standalone.capabilities == ToolCapabilities(canMoveToTrash: true))

        let brew = try #require(node.installation("homebrew:node"))
        #expect(brew.ownership.confidence == .confirmed)
        #expect(brew.linkState == .shadowed)
        #expect(brew.version?.value.rawValue == "26.7.0")
        #expect(brew.version?.source == .provider(.homebrew))
        #expect(brew.executables.first?.pathPriority == 11)
        #expect(brew.capabilities.canUpdate && brew.capabilities.canUninstall && !brew.capabilities.canMoveToTrash)

        #expect(node.resolution?.chain.map(\.pathPriority) == [10, 11])
        let conflict = try #require(snapshot.issue("pathConflict:node"))
        #expect(conflict.severity == .warning)
        #expect(Set(conflict.installationIDs) == ["path:\(home)/.local/bin/node", "homebrew:node"])
        #expect(node.health.status == .pathConflict)

        // Homebrew's node has an inventory version; only the standalone one is probed.
        #expect(scenario.runner.invocations.filter { $0.command.arguments == ["--version"] }.map(\.command.executable) == ["\(home)/.local/bin/node"])
        #expect(snapshot.versionCache["\(home)/.local/opt/node-v26.2.0-darwin-arm64/bin/node"]?.version == "26.2.0")
    }

    // MARK: php — keg-only sibling (§6.5)

    @Test func phpAndKegOnlyPHP82ShareOneTool() async throws {
        let scenario = EngineScenario()
        scenario.executable("/opt/homebrew/Cellar/php/8.5.7/bin/php")
        scenario.link("/opt/homebrew/bin/php", to: "../Cellar/php/8.5.7/bin/php")
        scenario.executable("/opt/homebrew/Cellar/php@8.2/8.2.31/bin/php")
        scenario.link("/opt/homebrew/opt/php@8.2", to: "../Cellar/php@8.2/8.2.31")
        scenario.fs.addFile("/opt/homebrew/etc/php/8.5/php.ini")
        scenario.fs.addFile("/opt/homebrew/etc/php/8.2/php.ini")

        let inventory = homebrewInventory([
            formula("php", "8.5.7", latest: "8.5.10", direct: false, executables: ["php"], dependencies: ["icu4c@78"]),
            formula("php@8.2", "8.2.31", latest: "8.2.31", kegOnly: true, executables: ["php"], paths: ["/opt/homebrew/opt/php@8.2/bin/php"], dependencies: ["icu4c@78"]),
            formula("icu4c@78", "78.1", direct: false),
        ], services: [ProviderService(providerID: .homebrew, name: "php", status: .stopped, plistPath: "/opt/homebrew/opt/php/homebrew.mxcl.php.plist")])
        let snapshot = await scenario.build(inventories: [inventory])
        let php = try #require(snapshot.tool("php"))

        #expect(php.installations.map(\.id) == ["homebrew:php", "homebrew:php@8.2"])
        let current = try #require(php.installation("homebrew:php"))
        #expect(current.linkState == .active)
        #expect(current.isDirect == false)
        #expect(current.version?.value.rawValue == "8.5.7")
        #expect(current.latest?.value.rawValue == "8.5.10")
        #expect(current.hasUpdate && current.updateKind == .patch)
        #expect(current.configPaths == ["/opt/homebrew/etc/php/8.5/php.ini"])
        #expect(current.capabilities.canStart && current.capabilities.canOpenConfig)

        let legacy = try #require(php.installation("homebrew:php@8.2"))
        #expect(legacy.linkState == .notOnPath)
        #expect(legacy.ownership.confidence == .confirmed)
        #expect(legacy.executables.map(\.path) == ["/opt/homebrew/opt/php@8.2/bin/php"])
        #expect(legacy.executables.first?.pathPriority == nil)
        #expect(legacy.configPaths == ["/opt/homebrew/etc/php/8.2/php.ini"])
        #expect(!legacy.capabilities.canStart)

        #expect(php.identity.category == .runtime)
        #expect(php.service?.name == "php")
        #expect(snapshot.issue("duplicateInstallation:php")?.severity == .info)
        #expect(snapshot.issue("pathConflict:php") == nil)
        #expect(!snapshot.issues.contains { $0.type == .brokenActiveExecutable })

        let icu = try #require(snapshot.tool("homebrew.icu4c@78"))
        #expect(icu.identity.category == .dependency)
        #expect(icu.installations.first?.dependents == ["php", "php@8.2"])
        #expect(icu.installations.first?.linkState == .notOnPath)
        #expect(scenario.runner.invocations.isEmpty, "Inventory versions need no probes")
    }

    // MARK: python3 — Homebrew plus system shim (F13)

    @Test func systemShimDuplicateIsNotReported() async throws {
        let scenario = EngineScenario()
        scenario.executable("/opt/homebrew/Cellar/python@3.14/3.14.4_1/bin/python3")
        scenario.link("/opt/homebrew/bin/python3", to: "../Cellar/python@3.14/3.14.4_1/bin/python3")
        scenario.executable("/usr/bin/python3")
        scenario.runner.stub("python3", ["--version"], stdout: "Python 3.9.6\n")

        let snapshot = await scenario.build(inventories: [homebrewInventory([formula("python@3.14", "3.14.4_1", latest: "3.14.7", executables: ["python3"])])])
        let python = try #require(snapshot.tool("python"))

        #expect(python.installations.count == 2)
        #expect(python.activeInstallationID == "homebrew:python@3.14")
        let system = try #require(python.installation("path:/usr/bin/python3"))
        #expect(system.isSystemManaged)
        #expect(system.linkState == .shadowed)
        #expect(system.capabilities == .none)
        #expect(system.version?.value.rawValue == "3.9.6")
        #expect(snapshot.issues(for: "python").isEmpty)
        #expect(python.health.status == .updateAvailable)
        #expect(scenario.probedNames == ["xcode-select", "python3"])
    }

    // MARK: Claude Code — native, confirmed by two evidences (C4)

    private func claudeScenario(probe: String = "2.1.234 (Claude Code)\n") -> EngineScenario {
        let scenario = EngineScenario()
        scenario.executable("\(home)/.local/share/claude/versions/2.1.234")
        scenario.link("\(home)/.local/bin/claude", to: "\(home)/.local/share/claude/versions/2.1.234")
        scenario.fs.addFile("\(home)/.claude/settings.json")
        scenario.runner.stub("claude", ["--version"], stdout: probe)
        return scenario
    }

    @Test func nativeClaudeCodeIsConfirmedAndUpdatable() async throws {
        let scenario = claudeScenario()
        // Real dist-tags (2026-09-13): stable and latest differ.
        scenario.executable("/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js")
        scenario.link("/opt/homebrew/bin/npm", to: "../lib/node_modules/npm/bin/npm-cli.js")
        scenario.runner.stub("npm", ["view", "@anthropic-ai/claude-code", "dist-tags", "--json"], stdout: #"{"stable":"2.1.236","latest":"2.1.270"}"#)

        let snapshot = await scenario.build(depth: .deep)
        let claude = try #require(snapshot.tool("claude-code"))
        let native = try #require(claude.installations.first)

        #expect(claude.installations.count == 1)
        #expect(native.id == "path:\(home)/.local/bin/claude")
        #expect(native.ownership.provider == .native)
        #expect(native.ownership.confidence == .confirmed)
        #expect(native.ownership.evidence == [.knownLayout("\(home)/.local/share/claude/versions"), .versionMatches("2.1.234")])
        #expect(native.version?.value.rawValue == "2.1.234")
        #expect(native.version?.source == .path)
        #expect(native.version?.confidence == .confirmed)
        #expect(native.installPrefix == "\(home)/.local/share/claude/versions/2.1.234")
        #expect(native.capabilities.canUpdate && !native.capabilities.canUninstall && !native.capabilities.canMoveToTrash)
        #expect(native.configPaths == ["\(home)/.claude/settings.json"])

        #expect(native.latest?.value.rawValue == "2.1.270")
        #expect(native.latest?.source == .updateSource("npm:@anthropic-ai/claude-code"))
        #expect(native.latestChannel == "latest")
        #expect(claude.hasUpdate)
        #expect(claude.health.status == .updateAvailable)
        #expect(snapshot.issues(for: "claude-code").isEmpty, "Updates are never issues (C7)")

        let npmView = try #require(scenario.runner.invocations.first { $0.command.arguments.first == "view" })
        #expect(npmView.command.executable == "/opt/homebrew/bin/npm")
    }

    @Test func fastScanKeepsPreviousLatestOnlyWhileVersionIsUnchanged() async throws {
        let scenario = claudeScenario()
        let source = StubUpdateSource(result: UpdateSourceResult(sourceID: "npm:@anthropic-ai/claude-code", channel: "latest", latestVersion: "2.1.270", channels: ["stable": "2.1.236", "latest": "2.1.270"]))
        let deep = await scenario.build(depth: .deep, updateSources: [source])
        #expect(deep.tool("claude-code")?.installations.first?.latest?.value.rawValue == "2.1.270")

        let fast = await scenario.build(previous: deep, depth: .fast, updateSources: [StubUpdateSource(result: nil)])
        let kept = try #require(fast.tool("claude-code")?.installations.first)
        #expect(kept.latest?.value.rawValue == "2.1.270")
        #expect(kept.latestChannel == "latest")
        #expect(scenario.runner.invocations.filter { $0.command.arguments == ["--version"] }.count == 1, "Second scan reuses the version cache")
        #expect(fast.tool("claude-code")?.installations.first?.ownership.confidence == .confirmed)

        // Upgraded in the meantime: the old latest no longer applies.
        scenario.executable("\(home)/.local/share/claude/versions/2.1.270")
        scenario.link("\(home)/.local/bin/claude", to: "\(home)/.local/share/claude/versions/2.1.270")
        scenario.runner.stub("claude", ["--version"], stdout: "2.1.270 (Claude Code)\n")
        let upgraded = await scenario.build(previous: fast, depth: .fast)
        let installation = try #require(upgraded.tool("claude-code")?.installations.first)
        #expect(installation.version?.value.rawValue == "2.1.270")
        #expect(installation.latest == nil)
    }

    @Test func nativeWithMismatchedProbeStaysProbable() async throws {
        let scenario = claudeScenario(probe: "2.1.200 (Claude Code)\n")
        let snapshot = await scenario.build()
        let native = try #require(snapshot.tool("claude-code")?.installations.first)
        #expect(native.ownership.confidence == .probable)
        #expect(!native.capabilities.canUpdate)
        #expect(native.version?.confidence == .probable)
    }

    // MARK: Kimi — standalone plus uv tool

    @Test func kimiStandaloneAndUvToolMerge() async throws {
        let scenario = EngineScenario()
        scenario.executable("\(home)/.kimi-code/bin/kimi")
        scenario.executable("\(home)/.local/share/uv/tools/kimi-cli/bin/kimi")
        scenario.executable("\(home)/.local/share/uv/tools/kimi-cli/bin/kimi-cli")
        scenario.link("\(home)/.local/bin/kimi", to: "\(home)/.local/share/uv/tools/kimi-cli/bin/kimi")
        scenario.link("\(home)/.local/bin/kimi-cli", to: "\(home)/.local/share/uv/tools/kimi-cli/bin/kimi-cli")
        scenario.runner.stub("kimi", ["--version"], stdout: "kimi, version 1.40.2\n")

        let uv = ProviderInventory(
            providerID: .uv,
            availability: ProviderAvailability(providerID: .uv, isAvailable: true, executable: "/opt/homebrew/bin/uv", version: "0.11.8"),
            layout: ProviderLayout(roots: [.uvToolDir: "\(home)/.local/share/uv/tools", .uvToolBinDir: "\(home)/.local/bin"]),
            tools: [ProviderTool(
                providerID: .uv, packageName: "kimi-cli", kind: .tool, installedVersions: ["1.49.0"], activeVersion: "1.49.0", latestVersion: "1.50.0",
                installPrefix: "\(home)/.local/share/uv/tools/kimi-cli", executableNames: ["kimi", "kimi-cli"],
                executablePaths: ["\(home)/.local/bin/kimi", "\(home)/.local/bin/kimi-cli"], isDirect: true
            )],
            depth: .deep,
            scannedAt: scanDate
        )
        let snapshot = await scenario.build(inventories: [uv])
        let kimi = try #require(snapshot.tool("kimi-cli"))

        #expect(kimi.installations.map(\.id) == ["path:\(home)/.kimi-code/bin/kimi", "uv:kimi-cli"])
        let standalone = try #require(kimi.installation("path:\(home)/.kimi-code/bin/kimi"))
        #expect(standalone.linkState == .active)
        #expect(standalone.executables.first?.pathPriority == 4)
        #expect(standalone.version?.value.rawValue == "1.40.2")

        let tool = try #require(kimi.installation("uv:kimi-cli"))
        #expect(tool.ownership.confidence == .confirmed)
        #expect(tool.ownership.evidence.contains(.symlinkResolvesInto("\(home)/.local/share/uv/tools/kimi-cli")))
        #expect(tool.linkState == .shadowed)
        #expect(tool.executables.map(\.name) == ["kimi", "kimi-cli"])
        #expect(tool.capabilities.canUpdate && tool.capabilities.canUninstall)
        #expect(tool.latest?.value.rawValue == "1.50.0")
        #expect(snapshot.issue("pathConflict:kimi-cli")?.severity == .warning)
    }

    /// Real shape (2026-09-13): Kimi Code's installer owns `~/.kimi-code/bin` (receipt in
    /// `updates/install.json`) and downloaded `rg` and `fd` there; the uv package's `kimi`
    /// entry point is linked as `kimi-legacy`, so only `kimi-cli` is uv's in PATH.
    private func kimiCodeScenario() -> (EngineScenario, ProviderInventory) {
        let scenario = EngineScenario()
        scenario.binary("\(home)/.kimi-code/bin/kimi", header: MachOHeader.arm64)
        scenario.binary("\(home)/.kimi-code/bin/kimi.bak", header: MachOHeader.arm64)
        scenario.binary("\(home)/.kimi-code/bin/rg", header: MachOHeader.arm64)
        scenario.binary("\(home)/.kimi-code/bin/fd", header: MachOHeader.arm64)
        scenario.fs.addFile("\(home)/.kimi-code/updates/install.json")
        scenario.executable("\(home)/.local/share/uv/tools/kimi-cli/bin/kimi")
        scenario.executable("\(home)/.local/share/uv/tools/kimi-cli/bin/kimi-cli")
        scenario.link("\(home)/.local/bin/kimi-cli", to: "\(home)/.local/share/uv/tools/kimi-cli/bin/kimi-cli")
        scenario.link("\(home)/.local/bin/kimi-legacy", to: "\(home)/.local/share/uv/tools/kimi-cli/bin/kimi")
        scenario.runner.stub("kimi", ["--version"], stdout: "0.36.1\n")
        scenario.runner.stub("rg", ["--version"], stdout: "ripgrep 15.0.0\n")

        let uv = ProviderInventory(
            providerID: .uv,
            availability: ProviderAvailability(providerID: .uv, isAvailable: true, executable: "/opt/homebrew/bin/uv", version: "0.11.8"),
            layout: ProviderLayout(roots: [.uvToolDir: "\(home)/.local/share/uv/tools", .uvToolBinDir: "\(home)/.local/bin"]),
            tools: [ProviderTool(
                providerID: .uv, packageName: "kimi-cli", kind: .tool, installedVersions: ["1.49.0"], activeVersion: "1.49.0", latestVersion: "1.50.0",
                installPrefix: "\(home)/.local/share/uv/tools/kimi-cli", executableNames: ["kimi", "kimi-cli"],
                executablePaths: ["\(home)/.local/bin/kimi", "\(home)/.local/bin/kimi-cli"], isDirect: true
            )],
            depth: .fast,
            scannedAt: scanDate
        )
        return (scenario, uv)
    }

    @Test func installationsWithDifferentCommandsAreDuplicatesNotConflicts() async throws {
        let (scenario, uv) = kimiCodeScenario()
        let snapshot = await scenario.build(inventories: [uv])
        let kimi = try #require(snapshot.tool("kimi-cli"))

        #expect(kimi.installations.map(\.id) == ["path:\(home)/.kimi-code/bin/kimi", "uv:kimi-cli"])
        #expect(kimi.installations.map(\.linkState) == [.active, .active])
        #expect(kimi.resolution?.command == "kimi")
        #expect(snapshot.issue("pathConflict:kimi-cli") == nil)
        let duplicate = try #require(snapshot.issue("duplicateInstallation:kimi-cli"))
        #expect(duplicate.severity == .info)
        #expect(Set(duplicate.installationIDs) == ["path:\(home)/.kimi-code/bin/kimi", "uv:kimi-cli"])
        #expect(kimi.health.status == .duplicateInstallation)
        #expect(snapshot.health == .good)
    }

    @Test func kimiCodeInstallerOwnsItsBundledHelpers() async throws {
        let (scenario, uv) = kimiCodeScenario()
        let snapshot = await scenario.build(inventories: [uv])
        let receipt = "\(home)/.kimi-code/updates/install.json"

        let kimi = try #require(snapshot.tool("kimi-cli")?.installation("path:\(home)/.kimi-code/bin/kimi"))
        #expect(kimi.ownership.provider == .native)
        #expect(kimi.ownership.confidence == .probable)
        #expect(kimi.ownership.packageName == nil)
        #expect(kimi.ownership.evidence == [.knownLayout("\(home)/.kimi-code/bin"), .knownLayout(receipt)])
        #expect(kimi.installPrefix == "\(home)/.kimi-code")
        #expect(kimi.executables.map(\.name) == ["fd", "kimi", "kimi.bak"])
        #expect(kimi.version?.value.rawValue == "0.36.1")
        #expect(!kimi.capabilities.canMoveToTrash)

        // ripgrep stays its own tool so a later Homebrew ripgrep still shows who wins in PATH.
        let ripgrep = try #require(snapshot.tool("ripgrep"))
        let bundled = try #require(ripgrep.installations.first)
        #expect(ripgrep.installations.count == 1)
        #expect(ripgrep.activeInstallationID == "path:\(home)/.kimi-code/bin/rg")
        #expect(bundled.ownership.provider == .native)
        #expect(bundled.ownership.packageName == "kimi-cli")
        #expect(bundled.ownership.evidence.contains(.knownLayout(receipt)))
        #expect(bundled.version?.value.rawValue == "15.0.0")
        #expect(bundled.capabilities == .none)

        #expect(!snapshot.tools.contains { $0.identity.category == .unrecognized })

        // Without the installer receipt the directory alone proves nothing (§37).
        scenario.fs.remove(receipt)
        let unmarked = await scenario.build(inventories: [uv])
        #expect(unmarked.tool("ripgrep")?.installations.first?.ownership.provider == .standalone)
        #expect(unmarked.tools.filter { $0.identity.category == .unrecognized }.map(\.identity.name).sorted() == ["fd", "kimi.bak"])
    }

    @Test func nodeAndNPMFromTwoNodeInstallationsStillConflict() async throws {
        let scenario = EngineScenario()
        let local = "\(home)/.local/opt/node-v26.2.0-darwin-arm64"
        scenario.executable("\(local)/bin/node")
        scenario.executable("\(local)/lib/node_modules/npm/bin/npm-cli.js")
        scenario.link("\(home)/.local/opt/node-current", to: "node-v26.2.0-darwin-arm64")
        scenario.link("\(home)/.local/bin/node", to: "\(home)/.local/opt/node-current/bin/node")
        scenario.link("\(home)/.local/bin/npm", to: "\(local)/lib/node_modules/npm/bin/npm-cli.js")
        scenario.executable("/opt/homebrew/Cellar/node/26.7.0/bin/node")
        scenario.link("/opt/homebrew/bin/node", to: "../Cellar/node/26.7.0/bin/node")
        scenario.executable("/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js")
        scenario.link("/opt/homebrew/bin/npm", to: "../lib/node_modules/npm/bin/npm-cli.js")
        scenario.runner.stub("node", ["--version"], stdout: "v26.2.0\n")
        scenario.runner.stub("npm", ["--version"], stdout: "11.19.0\n")

        let snapshot = await scenario.build(inventories: [
            homebrewInventory([formula("node", "26.7.0", executables: ["node"])]),
            npmInventory(root: "\(local)/lib/node_modules", [npmPackage("npm", "12.0.1", executables: ["npm", "npx"])]),
        ])
        let node = try #require(snapshot.issue("pathConflict:node"))
        #expect(node.severity == .warning)
        #expect(node.details["commands"] == "node")
        let npm = try #require(snapshot.issue("pathConflict:npm"))
        #expect(npm.severity == .warning)
        #expect(npm.paths == ["\(home)/.local/bin/npm", "/opt/homebrew/bin/npm"])
        #expect(snapshot.tool("npm")?.health.status == .pathConflict)
    }

    // MARK: Homebrew Node's npm (F8)

    @Test func homebrewNodeNPMBelongsToHomebrewNodeRoot() async throws {
        let scenario = EngineScenario()
        scenario.executable("/opt/homebrew/Cellar/node/26.7.0/bin/node")
        scenario.link("/opt/homebrew/bin/node", to: "../Cellar/node/26.7.0/bin/node")
        scenario.executable("/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js")
        scenario.executable("/opt/homebrew/lib/node_modules/npm/bin/npx-cli.js")
        scenario.link("/opt/homebrew/bin/npm", to: "../lib/node_modules/npm/bin/npm-cli.js")
        scenario.link("/opt/homebrew/bin/npx", to: "../lib/node_modules/npm/bin/npx-cli.js")
        scenario.runner.stub("npm", ["--version"], stdout: "11.6.0\n")
        let brew = homebrewInventory([formula("node", "26.7.0", executables: ["node"])])

        let unscanned = await scenario.build(inventories: [brew])
        let npm = try #require(unscanned.tool("npm")?.installations.first)
        #expect(unscanned.tool("npm")?.installations.count == 1)
        #expect(npm.id == "npm@/opt/homebrew/lib/node_modules:npm")
        #expect(npm.ownership.provider == .npm)
        #expect(npm.ownership.confidence == .probable)
        #expect(npm.ownership.evidence.contains(.knownLayout("/opt/homebrew")))
        #expect(npm.executables.map(\.name) == ["npm", "npx"])
        #expect(npm.version?.value.rawValue == "11.6.0")
        #expect(npm.capabilities == .none)
        #expect(unscanned.issue("missingRuntime:npm") == nil)

        let scanned = await scenario.build(inventories: [brew, npmInventory(root: "/opt/homebrew/lib/node_modules", [npmPackage("npm", "11.6.0", latest: "11.7.0", executables: ["npm", "npx"])])])
        let confirmed = try #require(scanned.tool("npm")?.installations.first)
        #expect(confirmed.id == "npm@/opt/homebrew/lib/node_modules:npm")
        #expect(confirmed.ownership.confidence == .confirmed)
        #expect(confirmed.capabilities.canUpdate && confirmed.capabilities.canUninstall)
        #expect(confirmed.version?.source == .provider(.npm))
    }

    // MARK: Broken Homebrew link (F6)

    /// Real shape (2026-09-13): the cask's binary artifact points into the deleted app,
    /// and `brew info` still lists the cask with `/opt/homebrew/bin/codexbar` as its target.
    @Test func brokenLinkOfConfirmedCaskMarksItBroken() async throws {
        let scenario = EngineScenario()
        scenario.rawLink("/opt/homebrew/bin/codexbar", to: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI")
        let cask = ProviderTool(
            providerID: .homebrew, packageName: "codexbar", kind: .cask, displayName: "CodexBar",
            installedVersions: ["0.56.4"], activeVersion: "0.56.4", latestVersion: "0.60.0", isOutdated: true,
            installPrefix: "/opt/homebrew/Caskroom/codexbar/0.56.4", executableNames: ["codexbar"],
            executablePaths: ["/opt/homebrew/bin/codexbar"], isDirect: true
        )

        let snapshot = await scenario.build(inventories: [homebrewInventory([cask])])
        #expect(snapshot.brokenSymlinks.map(\.path) == ["/opt/homebrew/bin/codexbar"])
        #expect(snapshot.tools.map(\.id) == ["homebrew.codexbar"], "The dangling link must not also become an app-bundle tool")

        let tool = try #require(snapshot.tool("homebrew.codexbar"))
        let installation = try #require(tool.installations.first)
        #expect(tool.installations.count == 1)
        #expect(installation.id == "homebrew:codexbar")
        #expect(installation.linkState == .broken)
        #expect(installation.ownership.provider == .homebrew)
        #expect(installation.ownership.packageName == "codexbar")
        #expect(installation.version?.value.rawValue == "0.56.4")
        #expect(installation.capabilities.canMoveToTrash)
        #expect(tool.health.status == .broken)

        // One issue for the tool, carrying the link's destination; no separate broken-link issue.
        #expect(snapshot.issue("brokenSymlink:/opt/homebrew/bin/codexbar") == nil)
        let broken = try #require(snapshot.issue("brokenActiveExecutable:homebrew.codexbar"))
        #expect(broken.paths == ["/opt/homebrew/bin/codexbar", "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"])
        // A menu-bar app's CLI helper is not an unusable runtime (§149).
        #expect(broken.severity == .warning)
        #expect(snapshot.health == .attention)

        let candidate = try #require(snapshot.cleanupCandidates.first { $0.id == "brokenSymlink:/opt/homebrew/bin/codexbar" })
        #expect(candidate.kind == .brokenSymlink)
        #expect(candidate.risk == .low)
        #expect(candidate.providerID == .homebrew)
        #expect(candidate.plan?.steps == [.moveToTrash(path: "/opt/homebrew/bin/codexbar")])
        #expect(candidate.plan?.kind == .cleanup(.brokenSymlink))
        #expect(scenario.runner.invocations.isEmpty)
    }

    /// Real shape: Docker.app was deleted but its `/usr/local/bin` links remain, next to
    /// Homebrew's docker formulae; other dangling links point into apps and project venvs.
    @Test func brokenLinksWithoutAConfirmedPackageCreateNoTools() async throws {
        let scenario = EngineScenario()
        for name in ["docker", "docker-compose", "kubectl"] {
            scenario.rawLink("/usr/local/bin/\(name)", to: "/Applications/Docker.app/Contents/Resources/bin/\(name)")
        }
        scenario.executable("/opt/homebrew/Cellar/docker/29.6.1/bin/docker")
        scenario.link("/opt/homebrew/bin/docker", to: "../Cellar/docker/29.6.1/bin/docker")
        scenario.executable("/opt/homebrew/Cellar/docker-compose/5.2.0/bin/docker-compose")
        scenario.link("/opt/homebrew/bin/docker-compose", to: "../Cellar/docker-compose/5.2.0/bin/docker-compose")
        scenario.rawLink("\(home)/.mavis/bin/mavis", to: "/Applications/MiniMax Code.app/Contents/Resources/resources/daemon/cli.js")
        scenario.rawLink("\(home)/.local/bin/piper", to: "\(home)/projects/OpenMontage/.venv/bin/piper")
        // Registry command names and uninstalled Homebrew packages don't count either.
        scenario.rawLink("\(home)/.local/bin/node", to: "\(home)/.local/opt/node-v20.0.0-darwin-arm64/bin/node")
        scenario.rawLink("/opt/homebrew/bin/wget", to: "../Cellar/wget/1.25.0/bin/wget")

        let inventory = homebrewInventory([
            formula("docker", "29.6.1", latest: "29.8.0", executables: ["docker"]),
            formula("docker-compose", "5.2.0", latest: "5.5.1", executables: ["docker-compose"]),
        ])
        let snapshot = await scenario.build(inventories: [inventory])

        #expect(snapshot.tools.map(\.id) == ["homebrew.docker", "homebrew.docker-compose"])
        let docker = try #require(snapshot.tool("homebrew.docker"))
        #expect(docker.installations.map(\.id) == ["homebrew:docker"])
        #expect(docker.installations.first?.linkState == .active)
        #expect(docker.health.status == .updateAvailable)

        let broken = snapshot.brokenSymlinks.map(\.path)
        #expect(Set(broken) == [
            "/usr/local/bin/docker", "/usr/local/bin/docker-compose", "/usr/local/bin/kubectl", "\(home)/.mavis/bin/mavis",
            "\(home)/.local/bin/piper", "\(home)/.local/bin/node", "/opt/homebrew/bin/wget",
        ])
        for path in broken {
            let issue = try #require(snapshot.issue("brokenSymlink:\(path)"))
            #expect(issue.severity == .warning)
            #expect(issue.toolID == nil)
            let candidate = try #require(snapshot.cleanupCandidates.first { $0.id == "brokenSymlink:\(path)" })
            #expect(candidate.plan?.steps == [.moveToTrash(path: path)])
            #expect(candidate.providerID == nil)
        }
        #expect(!snapshot.issues.contains { $0.type == .brokenActiveExecutable })
        #expect(!snapshot.tools.contains { tool in tool.installations.contains { $0.executables.contains { broken.contains($0.path) } } })
    }

    // MARK: System-owned problems (F3, F6)

    @Test func systemBrokenLinksAndMountPointsAreInfo() async throws {
        let cryptex = "/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin"
        let scenario = EngineScenario(path: ["/opt/homebrew/bin", "/usr/bin", "/usr/sbin", cryptex, "/System/Cryptexes/Gone/usr/bin"])
        scenario.fs.remove(cryptex)
        scenario.fs.remove("/System/Cryptexes/Gone/usr/bin")
        scenario.rawLink("/usr/sbin/weakpass_edit", to: "/usr/sbin/authserver/tools/weakpass")

        let snapshot = await scenario.build()
        let link = try #require(snapshot.issue("brokenSymlink:/usr/sbin/weakpass_edit"))
        #expect(link.severity == .info)
        #expect(snapshot.issue("missingPathEntry:\(cryptex)")?.severity == .info)
        #expect(snapshot.issue("missingPathEntry:/System/Cryptexes/Gone/usr/bin")?.severity == .info)
        #expect(snapshot.cleanupCandidates.isEmpty)
        #expect(snapshot.tools.isEmpty)
        #expect(snapshot.health == .good)

        // User-owned entries stay warnings.
        let herd = "\(home)/Library/Application Support/Herd/bin/"
        let user = EngineScenario(path: [herd, "/pkg/env/global/bin", cryptex, "/usr/bin"])
        user.fs.remove("\(home)/Library/Application Support/Herd/bin")
        user.fs.remove("/pkg/env/global/bin")
        user.fs.remove(cryptex)
        let userSnapshot = await user.build()
        #expect(userSnapshot.issue("missingPathEntry:\(home)/Library/Application Support/Herd/bin")?.severity == .warning)
        #expect(userSnapshot.issue("missingPathEntry:/pkg/env/global/bin")?.severity == .warning)
        #expect(userSnapshot.issue("missingPathEntry:\(cryptex)")?.severity == .info)
        #expect(userSnapshot.health == .attention)
    }

    // MARK: Unknown executables (§41)

    @Test func unknownExecutableGetsStableIDAndIsNeverRun() async throws {
        let scenario = EngineScenario()
        scenario.executable("\(home)/.grok/bin/grok")

        let first = await scenario.build()
        let second = await scenario.build(previous: first)
        let expectedID = MergeEngine.unknownToolID(name: "grok", location: "\(home)/.grok/bin/grok")

        let grok = try #require(first.tools.first { $0.identity.name == "grok" })
        #expect(grok.id == expectedID)
        #expect(grok.id.rawValue.hasPrefix("unknown.") && grok.id.rawValue.count == "unknown.".count + 64)
        #expect(second.tools.first { $0.identity.name == "grok" }?.id == expectedID)
        #expect(grok.identity.category == .unrecognized)
        #expect(grok.installations.first?.version == nil)
        #expect(grok.installations.first?.capabilities == ToolCapabilities(canMoveToTrash: true))
        #expect(grok.health.status == .unknown)
        #expect(!scenario.runner.invocations.contains { $0.command.executable.contains("grok") })
    }

    // MARK: Probe safety (F5)

    /// Real shape (2026-09-13): `/usr/bin/java` and `javac` exist, `java_home` finds no JDK.
    @Test func javaStubWithoutJDKIsNotAnInstalledTool() async throws {
        let scenario = EngineScenario()
        scenario.executable("/usr/bin/java")
        scenario.executable("/usr/bin/javac")
        scenario.runner.stub("java_home", [], stderr: "Unable to locate a Java Runtime.\n", exitCode: 1)

        let snapshot = await scenario.build()
        #expect(snapshot.tool("java") == nil)
        #expect(snapshot.issues.isEmpty)
        #expect(scenario.probedNames.contains("java_home"))
        #expect(!scenario.runner.invocations.contains { $0.command.executable.hasPrefix("/usr/bin/java") })

        // With a JDK the same stub is Java.
        scenario.runner.stub("java_home", [], stdout: "/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home\n")
        scenario.runner.stub("java", ["-version"], stderr: "openjdk version \"21.0.2\" 2024-01-16\n")
        let withJDK = await scenario.build()
        let java = try #require(withJDK.tool("java")?.installations.first)
        #expect(java.isSystemManaged)
        #expect(java.version?.value.rawValue == "21.0.2")

        // JDK removed later: the stub file is unchanged, but the cached version must not keep Java listed.
        scenario.runner.stub("java_home", [], stderr: "Unable to locate a Java Runtime.\n", exitCode: 1)
        let removed = await scenario.build(previous: withJDK)
        #expect(!withJDK.versionCache.isEmpty)
        #expect(removed.tool("java") == nil)
    }

    @Test func developerToolShimsWithoutCLTAreNotInstalledTools() async throws {
        let scenario = EngineScenario()
        scenario.executable("/usr/bin/git")
        scenario.executable("/usr/bin/pip3")
        scenario.executable("/usr/bin/curl")
        scenario.runner.stub("xcode-select", ["-p"], stderr: "xcode-select: error: unable to get active developer directory\n", exitCode: 2)

        let snapshot = await scenario.build()
        #expect(snapshot.tool("git") == nil)
        #expect(snapshot.tool("pip") == nil)
        // curl is a real system binary, not an xcselect shim; it just isn't probed without the CLT.
        let curl = try #require(snapshot.tool("curl")?.installations.first)
        #expect(curl.isSystemManaged)
        #expect(curl.version == nil)
        #expect(scenario.probedNames == ["xcode-select"])

        scenario.runner.stub("xcode-select", ["-p"], stdout: "/Library/Developer/CommandLineTools\n")
        scenario.runner.stub("git", ["--version"], stdout: "git version 2.50.1 (Apple Git-155)\n")
        let allowed = await scenario.build()
        #expect(allowed.tool("git")?.installations.first?.version?.value.rawValue == "2.50.1")
    }

    @Test func pythonStubWithoutCLTKeepsOtherInstallations() async throws {
        let scenario = EngineScenario()
        scenario.executable("/opt/homebrew/Cellar/python@3.14/3.14.4_1/bin/python3")
        scenario.link("/opt/homebrew/bin/python3", to: "../Cellar/python@3.14/3.14.4_1/bin/python3")
        scenario.executable("/usr/bin/python3")
        scenario.runner.stub("xcode-select", ["-p"], stderr: "error\n", exitCode: 2)

        let snapshot = await scenario.build(inventories: [homebrewInventory([formula("python@3.14", "3.14.4_1", executables: ["python3"])])])
        let python = try #require(snapshot.tool("python"))
        #expect(python.installations.map(\.id) == ["homebrew:python@3.14", "path:/usr/bin/python3"])
        #expect(python.activeInstallationID == "homebrew:python@3.14")
    }

    // MARK: Unknown executables reached through several PATH entries

    /// Real shape: `~/.local/bin/agent → ~/.grok/bin/agent → ../downloads/grok-…`, both directories in PATH.
    @Test func unknownExecutablesResolvingToOneFileAreOneTool() async throws {
        let scenario = EngineScenario()
        let download = "\(home)/.grok/downloads/grok-1.0.25-macos-aarch64"
        scenario.binary(download, header: MachOHeader.arm64)
        scenario.link("\(home)/.grok/bin/agent", to: "../downloads/grok-1.0.25-macos-aarch64")
        scenario.link("\(home)/.grok/bin/grok", to: "../downloads/grok-1.0.25-macos-aarch64")
        scenario.link("\(home)/.local/bin/agent", to: "\(home)/.grok/bin/agent")
        scenario.link("\(home)/.local/bin/grok", to: "\(home)/.grok/bin/grok")
        // Same name, different file: a separate tool.
        scenario.executable("\(home)/.opencode/bin/agent")

        let first = await scenario.build()
        let agents = first.tools.filter { $0.identity.name == "agent" }
        #expect(agents.count == 2)
        #expect(first.tools.filter { $0.identity.name == "grok" }.count == 1)

        let grokAgent = try #require(agents.first { $0.id == MergeEngine.unknownToolID(name: "agent", location: "\(home)/.grok/bin/agent") })
        let installation = try #require(grokAgent.installations.first)
        #expect(grokAgent.installations.count == 1)
        #expect(installation.id == "path:\(home)/.grok/bin/agent")
        #expect(installation.executables.map(\.path) == ["\(home)/.grok/bin/agent", "\(home)/.local/bin/agent"])
        #expect(installation.executables.map(\.pathPriority) == [5, 10])
        #expect(installation.linkState == .active)
        #expect(grokAgent.activeInstallationID == installation.id)
        #expect(first.issues.isEmpty)

        let other = try #require(agents.first { $0.id == MergeEngine.unknownToolID(name: "agent", location: "\(home)/.opencode/bin/agent") })
        #expect(other.installations.first?.linkState == .shadowed, "~/.grok/bin (#5) wins over ~/.opencode/bin (#8)")
        #expect(scenario.runner.invocations.isEmpty)

        let second = await scenario.build(previous: first)
        #expect(second.tools.map(\.id) == first.tools.map(\.id))
    }

    @Test func bunGlobalPackagesAreAttributedToBun() async throws {
        let scenario = EngineScenario()
        scenario.executable("\(home)/.bun/install/global/node_modules/@opencode-ai/cli/bin/opencode2")
        scenario.link("\(home)/.bun/bin/opencode2", to: "\(home)/.bun/install/global/node_modules/@opencode-ai/cli/bin/opencode2")

        let snapshot = await scenario.build()
        // bun installs from the npm registry, so the tool lives in the npm namespace.
        let tool = try #require(snapshot.tool("npm.@opencode-ai/cli"))
        let installation = try #require(tool.installations.first)
        #expect(installation.id == "bun:@opencode-ai/cli")
        #expect(installation.ownership.provider == .bun)
        #expect(installation.ownership.confidence == .probable)
        #expect(installation.installPrefix == "\(home)/.bun/install/global/node_modules/@opencode-ai/cli")
        #expect(installation.linkState == .active)
        #expect(!installation.capabilities.canMoveToTrash)
        #expect(!snapshot.tools.contains { $0.identity.category == .unrecognized })
    }
}
