import CLIStateDomain
@testable import CLIStateEngine
import CLIStateTestSupport
import Foundation
import Testing

@Suite("Update sources and safety")
struct UpdateSourceAndSafetyTests {
    @Test func npmDistTagsParseChannels() throws {
        let data = Data(#"{"stable":"2.1.236","latest":"2.1.270","next":"2.2.0-beta.1"}"#.utf8)
        let result = try #require(NPMDistTagUpdateSource.parse(data, package: "@anthropic-ai/claude-code", channel: "latest"))
        #expect(result.latestVersion == "2.1.270")
        #expect(result.channel == "latest")
        #expect(result.channels["stable"] == "2.1.236")
        #expect(result.sourceID == "npm:@anthropic-ai/claude-code")
        #expect(NPMDistTagUpdateSource.parse(data, package: "x", channel: "canary") == nil)
        #expect(NPMDistTagUpdateSource.parse(Data("npm ERR!".utf8), package: "x", channel: "latest") == nil)
    }

    /// npm 12.0.1 on the developer Mac wraps `npm view --json` output in an array.
    @Test func npmDistTagsParseArrayOutputFromNewerNPM() throws {
        let data = Data(#"[{"stable":"2.1.236","latest":"2.1.270","next":"2.1.270"}]"#.utf8)
        let result = try #require(NPMDistTagUpdateSource.parse(data, package: "@anthropic-ai/claude-code", channel: "latest"))
        #expect(result.latestVersion == "2.1.270")
        #expect(result.channels["stable"] == "2.1.236")
    }

    @Test func npmDistTagSourceNeedsNPMOnPath() async {
        let scenario = EngineScenario()
        let source = NPMDistTagUpdateSource(runner: scenario.runner)
        let result = await source.latest(for: .npmDistTags(package: "@anthropic-ai/claude-code", channel: "latest"), discovery: scenario.discovery())
        #expect(result == nil)
        #expect(scenario.runner.invocations.isEmpty)
    }

    @Test func fastScansNeverQueryUpdateSources() async throws {
        let scenario = EngineScenario()
        scenario.executable("\(home)/.local/share/claude/versions/2.1.234")
        scenario.link("\(home)/.local/bin/claude", to: "\(home)/.local/share/claude/versions/2.1.234")
        scenario.executable("/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js")
        scenario.link("/opt/homebrew/bin/npm", to: "../lib/node_modules/npm/bin/npm-cli.js")
        scenario.runner.stub("claude", ["--version"], stdout: "2.1.234 (Claude Code)\n")

        let snapshot = await scenario.build(depth: .fast)
        #expect(snapshot.tool("claude-code")?.installations.first?.latest == nil)
        #expect(!scenario.runner.invocations.contains { $0.command.arguments.first == "view" })
    }

    @Test func homebrewItselfIsNeverAnUnknownTrashCandidate() async throws {
        let scenario = EngineScenario()
        scenario.executable("/opt/homebrew/bin/brew", contents: "#!/bin/bash\n")
        scenario.runner.stub("brew", ["--version"], stdout: "Homebrew 6.0.22\n")

        let snapshot = await scenario.build()
        let brew = try #require(snapshot.tool("homebrew")?.installations.first)
        #expect(brew.ownership.provider == .homebrew)
        #expect(brew.ownership.confidence == .probable)
        #expect(!brew.capabilities.canMoveToTrash && !brew.capabilities.canUninstall)
        #expect(brew.version?.value.rawValue == "6.0.22")
        #expect(!snapshot.tools.contains { $0.identity.category == .unrecognized })
    }

    @Test func systemExecutablesOutsideTheRegistryAreNotTools() async {
        let scenario = EngineScenario()
        for name in ["zip", "ssh", "tclsh"] { scenario.executable("/usr/bin/\(name)") }
        scenario.executable("/System/Cryptexes/App/usr/bin/safari-helper")
        let snapshot = await scenario.build()
        #expect(snapshot.tools.isEmpty)
        #expect(scenario.runner.invocations.isEmpty)
    }

    @Test func scalesToThousandsOfExecutables() async {
        let directories = (0..<100).map { "/opt/scale/dir\($0)/bin" }
        let scenario = EngineScenario(path: directories)
        for (index, directory) in directories.enumerated() {
            for binary in 0..<50 {
                scenario.executable("\(directory)/tool\(index)-\(binary)")
            }
        }
        let clock = ContinuousClock()
        let started = clock.now
        let snapshot = await scenario.build()
        #expect(snapshot.tools.count == 5000)
        #expect(snapshot.tools.allSatisfy { $0.identity.category == .unrecognized })
        #expect(scenario.runner.invocations.isEmpty)
        #expect(clock.now - started < .seconds(30))
    }
}
