@testable import CLIStateApplication
import CLIStateDomain
import Foundation
import Testing

private let scanDate = Date(timeIntervalSince1970: 1_700_000_000)

private func observed(_ version: String) -> ObservedValue<ToolVersion> {
    ObservedValue(ToolVersion(version), source: .provider(.homebrew), confidence: .confirmed, observedAt: scanDate)
}

private func installation(
    _ id: InstallationID,
    provider: ProviderID,
    package: String? = nil,
    version: String?,
    latest: String? = nil,
    executables: [ExecutableRef],
    canUpdate: Bool = true
) -> ToolInstallation {
    ToolInstallation(
        id: id,
        ownership: Ownership(provider: provider, packageName: package, confidence: .confirmed),
        version: version.map(observed),
        latest: latest.map(observed),
        executables: executables,
        linkState: executables.contains { $0.pathPriority == 1 } ? .active : .shadowed,
        capabilities: ToolCapabilities(canUpdate: canUpdate)
    )
}

private func tool(_ id: ToolID, _ name: String, _ installations: [ToolInstallation], category: ToolCategory = .runtime) -> Tool {
    Tool(id: id, identity: ToolIdentity(name: id.rawValue, displayName: name, category: category), installations: installations, activeInstallationID: installations.first?.id, health: ToolHealthState(status: .healthy), lastScannedAt: scanDate)
}

private func snapshot(tools: [Tool], shadows: [String: [ShellShadow]] = [:]) -> EnvironmentSnapshot {
    let shell = ShellEnvironment(shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh), path: [], variables: [:], shadows: shadows, source: .loginShell, capturedAt: scanDate)
    return EnvironmentSnapshot(capturedAt: scanDate, depth: .deep, shell: shell, pathEntries: [], brokenSymlinks: [], providers: [], tools: tools, services: [], issues: [])
}

/// Homebrew node first in PATH, nvm node later, and a keg-only python off PATH.
private let fixtureTools: [Tool] = [
    tool("node", "Node.js", [
        installation("nvm:node:20", provider: .nvm, version: "20.11.0", executables: [ExecutableRef(name: "node", path: "/Users/me/.nvm/versions/node/v20.11.0/bin/node", pathPriority: 4)]),
        installation("homebrew:node", provider: .homebrew, package: "node", version: "22.1.0", latest: "22.2.0", executables: [
            ExecutableRef(name: "node", path: "/opt/homebrew/bin/node", pathPriority: 1),
            ExecutableRef(name: "npx", path: "/opt/homebrew/bin/npx", pathPriority: 1),
        ]),
    ]),
    tool("python@3.12", "Python 3.12", [
        installation("homebrew:python@3.12", provider: .homebrew, package: "python@3.12", version: "3.12.4", latest: "3.12.5", executables: [ExecutableRef(name: "python3.12", path: "/opt/homebrew/opt/python@3.12/bin/python3.12")], canUpdate: false),
    ]),
    tool("claude-code", "Claude Code", [
        installation("native:claude", provider: .native, version: "2.0.1", latest: "2.0.1", executables: [ExecutableRef(name: "claude", path: "/Users/me/.local/bin/claude", pathPriority: 2)]),
    ], category: .aiCLI),
    tool("nodemon", "nodemon", [
        installation("npm:nodemon", provider: .npm, package: "nodemon", version: "3.0.0", latest: "3.1.0", executables: [ExecutableRef(name: "nodemon", path: "/opt/homebrew/bin/nodemon", pathPriority: 1)]),
    ], category: .developerTool),
]

@Suite("Command lookup")
struct CommandLookupTests {
    @Test func normalizesCommandInput() {
        #expect(CommandLookup.commandName(from: "  node ") == "node")
        #expect(CommandLookup.commandName(from: "which -a node") == "node")
        #expect(CommandLookup.commandName(from: "/opt/homebrew/bin/node") == "node")
        #expect(CommandLookup.commandName(from: "   ") == "")
    }

    @Test func activeMatchComesFirstAndLaterOnesAreShadowed() throws {
        let lookup = CommandLookup(command: "node", in: snapshot(tools: fixtureTools, shadows: ["node": [ShellShadow(name: "node", kind: .alias, detail: "node --inspect")]]))
        let active = try #require(lookup.active)
        #expect(active.executable.path == "/opt/homebrew/bin/node")
        #expect(active.provider == .homebrew)
        #expect(active.version == "22.1.0")
        #expect(active.toolName == "Node.js")
        #expect(lookup.shadowed.map(\.executable.path) == ["/Users/me/.nvm/versions/node/v20.11.0/bin/node"])
        #expect(lookup.shellShadows.map(\.kind) == [.alias])
        #expect(lookup.offPath.isEmpty)
    }

    @Test func offPathExecutablesAreReportedSeparately() {
        let lookup = CommandLookup(command: "python3.12", in: snapshot(tools: fixtureTools))
        #expect(lookup.active == nil)
        #expect(lookup.offPath.map(\.installationID) == ["homebrew:python@3.12"])
        #expect(lookup.isFound)
    }

    @Test func unknownCommandFindsNothing() {
        let lookup = CommandLookup(command: "doesnotexist", in: snapshot(tools: fixtureTools))
        #expect(!lookup.isFound)
        #expect(lookup.shellShadows.isEmpty)
    }
}

@Suite("Tool search")
struct ToolSearchTests {
    @Test func exactMatchesRankBeforePrefixAndSubstring() {
        let ranked = ToolSearch.rank(fixtureTools, query: "node").map(\.id)
        #expect(ranked == ["node", "nodemon"])
    }

    @Test func matchesExecutablesPackagesAndProviders() {
        #expect(ToolSearch.rank(fixtureTools, query: "claude").map(\.id) == ["claude-code"])
        #expect(ToolSearch.rank(fixtureTools, query: "NPX").map(\.id) == ["node"])
        #expect(ToolSearch.rank(fixtureTools, query: "python@3").map(\.id) == ["python@3.12"])
        #expect(Set(ToolSearch.rank(fixtureTools, query: "homebrew").map(\.id)) == ["node", "python@3.12"])
    }

    @Test func emptyQueryListsEverythingByName() {
        #expect(ToolSearch.rank(fixtureTools, query: " ").map(\.identity.displayName) == ["Claude Code", "Node.js", "nodemon", "Python 3.12"])
    }
}

@Suite("Environment digest")
struct EnvironmentDigestTests {
    @Test func listsUpdatesByNameAndLeavesOutSkippedVersions() {
        let digest = EnvironmentDigest(tools: fixtureTools, issues: [], skippedVersions: ["npm:nodemon": "3.1.0"])
        #expect(digest.toolCount == 4)
        #expect(digest.updates.map(\.installationID) == ["homebrew:node", "homebrew:python@3.12"])
        #expect(digest.updates.first?.installedVersion == "22.1.0")
        #expect(digest.updates.first?.latestVersion == "22.2.0")
        #expect(digest.updates.first?.updateKind == .minor)
        #expect(digest.hasUpdatableItems)
    }

    @Test func skippingAnOlderVersionStillShowsTheNewOne() {
        let digest = EnvironmentDigest(tools: fixtureTools, issues: [], skippedVersions: ["npm:nodemon": "3.0.5"])
        #expect(digest.updates.contains { $0.installationID == "npm:nodemon" })
    }

    @Test func topUpdatesReportsTheRemainder() {
        let digest = EnvironmentDigest(tools: fixtureTools, issues: [])
        let top = digest.topUpdates(limit: 2)
        #expect(top.shown.map(\.name) == ["Node.js", "nodemon"])
        #expect(top.remaining == 1)
        #expect(digest.topUpdates(limit: 5).remaining == 0)
    }

    @Test func issueBreakdownPutsCriticalFirst() {
        let issues = [
            HealthIssue(type: .duplicatePathEntry, severity: .info, subject: "/usr/local/bin"),
            HealthIssue(type: .pathConflict, severity: .warning, subject: "node"),
            HealthIssue(type: .brokenActiveExecutable, severity: .critical, subject: "python3"),
            HealthIssue(type: .brokenSymlink, severity: .warning, subject: "/opt/homebrew/bin/x"),
        ]
        let summary = IssueSummary(issues)
        #expect(summary.total == 4)
        #expect(summary.worst == .critical)
        #expect(summary.breakdown.map(\.severity) == [.critical, .warning, .info])
        #expect(summary.breakdown.map(\.count) == [1, 2, 1])
        #expect(IssueSummary([]).worst == nil)
    }
}
