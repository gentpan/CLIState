import CLIStateDomain
@testable import CLIStateEngine
import CLIStateTestSupport
import Foundation
import Testing

@Suite("Health, provider state and cleanup")
struct HealthAndProviderStateTests {
    @Test func pathEntryIssues() async throws {
        let scenario = EngineScenario(path: ["/opt/homebrew/bin", "\(home)/missing/bin", "/opt/homebrew/bin/", ".", "/usr/bin"])
        scenario.fs.remove("\(home)/missing/bin")
        let snapshot = await scenario.build()

        let missing = try #require(snapshot.issue("missingPathEntry:\(home)/missing/bin"))
        #expect(missing.severity == .warning)
        let duplicate = try #require(snapshot.issue("duplicatePathEntry:/opt/homebrew/bin"))
        #expect(duplicate.severity == .info)
        #expect(duplicate.details["duplicateOf"] == "1")
        #expect(snapshot.issue("relativePathEntry:.")?.severity == .warning)
        #expect(snapshot.health == .attention)
    }

    @Test func npmWithoutNodeIsMissingRuntimeUnlessAShellFunctionProvidesIt() async throws {
        let scenario = EngineScenario()
        scenario.executable("/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js")
        scenario.link("/opt/homebrew/bin/npm", to: "../lib/node_modules/npm/bin/npm-cli.js")

        let snapshot = await scenario.build()
        let issue = try #require(snapshot.issue("missingRuntime:npm"))
        #expect(issue.severity == .warning)
        #expect(issue.toolID == "npm")
        #expect(issue.details["runtime"] == "node")
        #expect(issue.paths == ["/opt/homebrew/bin/npm"])

        scenario.shadows = ["node": [ShellShadow(name: "node", kind: .function, detail: "nvm lazy load")]]
        let lazy = await scenario.build()
        #expect(lazy.issue("missingRuntime:npm") == nil)
    }

    @Test func failedNPMProviderKeepsPreviousToolsAsStale() async throws {
        let root = "\(home)/.local/opt/node-v26.2.0-darwin-arm64/lib/node_modules"
        let scenario = EngineScenario(path: ["\(home)/.local/opt/node-v26.2.0-darwin-arm64/bin", "/usr/bin"])
        scenario.executable("\(home)/.local/opt/node-v26.2.0-darwin-arm64/bin/node")
        scenario.executable("\(root)/@mimo-ai/cli/bin/mimo.js")
        scenario.link("\(home)/.local/opt/node-v26.2.0-darwin-arm64/bin/mimo", to: "../lib/node_modules/@mimo-ai/cli/bin/mimo.js")
        scenario.executable("\(root)/pnpm/bin/pnpm.cjs")
        scenario.link("\(home)/.local/opt/node-v26.2.0-darwin-arm64/bin/pnpm", to: "../lib/node_modules/pnpm/bin/pnpm.cjs")
        scenario.runner.stub("node", ["--version"], stdout: "v26.2.0\n")

        let firstDate = scanDate
        let inventory = npmInventory(root: root, [
            npmPackage("@mimo-ai/cli", "0.1.0", latest: "0.1.14", executables: ["mimo"]),
            npmPackage("pnpm", "10.33.0", latest: "12.4.1", executables: ["pnpm"]),
        ], depth: .deep, at: firstDate)
        let first = await scenario.build(inventories: [inventory], depth: .deep, now: firstDate)
        let mimoID = InstallationID("npm@\(root):@mimo-ai/cli")
        #expect(first.tool("npm.@mimo-ai/cli")?.installation(mimoID)?.ownership.confidence == .confirmed)
        #expect(first.tool("npm.@mimo-ai/cli")?.identity.category == .developerTool)

        let later = firstDate.addingTimeInterval(3600)
        let second = await scenario.build(failed: [.npm: "npm list exited with 1"], previous: first, now: later)

        let mimo = try #require(second.tool("npm.@mimo-ai/cli")?.installation(mimoID))
        #expect(mimo.version?.value.rawValue == "0.1.0")
        #expect(mimo.latest?.value.rawValue == "0.1.14")
        #expect(mimo.ownership.confidence == .confirmed)
        #expect(mimo.linkState == .active)
        #expect(second.tool("pnpm")?.installations.first?.version?.value.rawValue == "10.33.0")

        let provider = try #require(second.providers.first { $0.providerID == .npm })
        #expect(provider.freshness == .stale(firstDate))
        #expect(provider.lastError == "npm list exited with 1")
        #expect(provider.layout[.npmGlobalRoot] == root)
        #expect(provider.toolCount == 2)
        let issue = try #require(second.issue("providerScanFailed:npm"))
        #expect(issue.severity == .warning)

        // A failure with no history has nothing to keep.
        let cold = await scenario.build(failed: [.npm: "npm not responding"])
        #expect(cold.providers.first { $0.providerID == .npm }?.freshness == .unavailable)
        #expect(cold.tool("npm.@mimo-ai/cli")?.installations.first?.ownership.confidence != .confirmed)
        #expect(cold.issue("providerScanFailed:npm") != nil)
    }

    @Test func servicesAttachAndFailuresAreCritical() async throws {
        let scenario = EngineScenario()
        scenario.executable("/opt/homebrew/Cellar/postgresql@17/17.10/bin/psql")
        scenario.link("/opt/homebrew/opt/postgresql@17", to: "../Cellar/postgresql@17/17.10")
        let inventory = homebrewInventory(
            [formula("postgresql@17", "17.10", kegOnly: true, executables: ["psql"])],
            services: [
                ProviderService(providerID: .homebrew, name: "postgresql@17", status: .error, rawStatus: "error", user: "tester", plistPath: "\(home)/Library/LaunchAgents/homebrew.mxcl.postgresql@17.plist", exitCode: 1),
                ProviderService(providerID: .homebrew, name: "colima", status: .stopped),
            ]
        )
        let snapshot = await scenario.build(inventories: [inventory])
        let postgres = try #require(snapshot.tool("postgresql"))
        #expect(postgres.service?.id == "homebrew:postgresql@17")
        #expect(postgres.service?.installationID == "homebrew:postgresql@17")
        let installation = try #require(postgres.installations.first)
        #expect(installation.capabilities.canStart && installation.capabilities.canStop && installation.capabilities.canRestart)
        #expect(installation.executables.map(\.path) == ["/opt/homebrew/Cellar/postgresql@17/17.10/bin/psql"])

        let failed = try #require(snapshot.issue("failedService:postgresql@17"))
        #expect(failed.severity == .critical)
        #expect(failed.toolID == "postgresql")
        #expect(postgres.health.status == .broken)
        #expect(snapshot.health == .issuesFound)
        #expect(snapshot.services.map(\.id) == ["homebrew:colima", "homebrew:postgresql@17"])
        #expect(snapshot.services.first?.toolID == nil)
    }

    @Test func brokenInventoryPackageIsCritical() async throws {
        let scenario = EngineScenario()
        scenario.link("/opt/homebrew/bin/node", to: "../Cellar/node/26.6.0/bin/node")
        let snapshot = await scenario.build(inventories: [homebrewInventory([formula("node", "26.7.0", executables: ["node"])])])
        let issue = try #require(snapshot.issue("brokenActiveExecutable:node"))
        #expect(issue.severity == .critical)
        #expect(snapshot.issue("brokenSymlink:/opt/homebrew/bin/node") == nil, "folded into the tool issue")
        #expect(issue.paths.contains("/opt/homebrew/Cellar/node/26.6.0/bin/node"))
        #expect(snapshot.tool("node")?.installation("homebrew:node")?.linkState == .broken)
    }

    @Test func versionManagerRuntimesAndUnusedRuntimeSuggestions() async throws {
        let scenario = EngineScenario(path: ["\(home)/.nvm/versions/node/v22.11.0/bin", "/usr/bin"])
        scenario.executable("\(home)/.nvm/versions/node/v22.11.0/bin/node")
        scenario.executable("\(home)/.nvm/versions/node/v20.18.0/bin/node")
        scenario.link("\(home)/.nvm/versions/node/lts", to: "v22.11.0")

        let snapshot = await scenario.build()
        let node = try #require(snapshot.tool("node"))
        #expect(node.installations.count == 2)
        let active = try #require(node.installation("path:\(home)/.nvm/versions/node/v22.11.0/bin/node"))
        #expect(active.ownership.provider == .nvm)
        #expect(active.linkState == .active)
        #expect(active.version?.value.rawValue == "22.11.0")
        #expect(active.version?.source == .path)
        let inactive = try #require(node.installation("path:\(home)/.nvm/versions/node/v20.18.0/bin/node"))
        #expect(inactive.linkState == .notOnPath)
        #expect(snapshot.issue("duplicateInstallation:node")?.severity == .info)
        #expect(scenario.runner.invocations.isEmpty, "Path versions need no probe")

        let suggestion = try #require(snapshot.cleanupCandidates.first { $0.kind == .unusedRuntime })
        #expect(suggestion.plan == nil)
        #expect(suggestion.providerID == .nvm)
        #expect(suggestion.paths == ["\(home)/.nvm/versions/node/v20.18.0"])
        #expect(suggestion.items.first?.fromVersion == "20.18.0")
        #expect(suggestion.id == "unusedRuntime:path:\(home)/.nvm/versions/node/v20.18.0/bin/node")
    }

    @Test func mixedArchitectureAndShellShadowingAreInfo() async throws {
        let scenario = EngineScenario()
        scenario.binary("\(home)/.local/bin/node", header: MachOHeader.x86_64)
        scenario.runner.stub("node", ["--version"], stdout: "v18.0.0\n")
        scenario.shadows = ["node": [ShellShadow(name: "node", kind: .function, detail: "node () { nvm use; }")]]

        let snapshot = await scenario.build()
        #expect(snapshot.tool("node")?.installations.first?.executables.first?.architecture == .x86_64)
        #expect(snapshot.issue("mixedArchitecture:node")?.severity == .info)
        let shadow = try #require(snapshot.issue("shellShadowing:node"))
        #expect(shadow.severity == .info)
        #expect(snapshot.tool("node")?.resolution?.shadows.first?.kind == .function)
        #expect(snapshot.health == .good)
    }

    @Test func buildsAreDeterministic() async throws {
        let scenario = EngineScenario()
        scenario.executable("\(home)/.grok/bin/grok")
        scenario.executable("/opt/homebrew/Cellar/php/8.5.7/bin/php")
        scenario.link("/opt/homebrew/bin/php", to: "../Cellar/php/8.5.7/bin/php")
        scenario.rawLink("/opt/homebrew/bin/codexbar", to: "../Caskroom/codexbar/0.56.4/CodexBar.app/Contents/Helpers/CodexBarCLI")
        scenario.link("\(home)/.local/bin/studio", to: "\(home)/Applications/Studio.app/Contents/MacOS/studio")
        let inventories = [homebrewInventory([formula("php", "8.5.7", latest: "8.5.10", executables: ["php"]), formula("aom", "3.14.1", direct: false)])]

        let first = await scenario.build(inventories: inventories)
        let second = await scenario.build(inventories: inventories)
        #expect(first.tools == second.tools)
        #expect(first.issues == second.issues)
        #expect(first.cleanupCandidates == second.cleanupCandidates)
        #expect(first.tools.map(\.id) == first.tools.map(\.id).sorted())
        #expect(first.cleanupCandidates.map(\.id) == ["brokenSymlink:\(home)/.local/bin/studio", "brokenSymlink:/opt/homebrew/bin/codexbar"])
        #expect(first.tool("homebrew.aom")?.installations.first?.ownership.confidence == .confirmed)
        #expect(first.issues.map(\.severity) == first.issues.map(\.severity).sorted(by: >))

        let encoded = try JSONEncoder().encode(first)
        let decoded = try JSONDecoder().decode(EnvironmentSnapshot.self, from: encoded)
        #expect(decoded.tools == first.tools)
    }
}
