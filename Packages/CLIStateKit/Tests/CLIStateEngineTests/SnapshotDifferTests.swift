import CLIStateDomain
@testable import CLIStateEngine
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_789_000_000)
private let t1 = t0.addingTimeInterval(3600)

@Suite("Snapshot differ and change attribution")
struct SnapshotDifferTests {
    // MARK: Tools and installations

    @Test func identicalSnapshotsProduceNothing() {
        let snapshot = makeSnapshot(tools: [nodeTool(brew("node", "24.1.0"))])
        #expect(SnapshotDiffer().changes(from: snapshot, to: snapshot).isEmpty)
    }

    @Test func versionChangeIgnoresLatestMetadataAndTimestamps() throws {
        var old = brew("node", "24.1.0")
        old.latest = observed("24.2.0")
        var new = brew("node", "24.2.0")
        new.latest = nil
        let before = makeSnapshot(tools: [nodeTool(old)], at: t0, depth: .deep)
        let after = makeSnapshot(tools: [nodeTool(new, scannedAt: t1)], at: t1)
        let changes = SnapshotDiffer().changes(from: before, to: after)
        let change = try #require(changes.first)
        #expect(changes.count == 1)
        #expect(change.kind == .versionChanged)
        #expect(change.from == "24.1.0" && change.to == "24.2.0")
        #expect(change.installationID == "homebrew:node")
        #expect(change.provider == .homebrew)
        #expect(change.toolName == "Node.js")
    }

    @Test func fastScanAfterDeepScanOnlyLosingMetadataIsQuiet() {
        var deep = brew("node", "24.1.0")
        deep.latest = observed("24.2.0")
        deep.latestChannel = "stable"
        var fast = brew("node", "24.1.0")
        fast.latest = nil
        // A probe that timed out is not a version change either.
        var unprobed = brew("php", "8.4.1")
        unprobed.version = nil
        let before = makeSnapshot(tools: [nodeTool(deep), tool("php", "PHP", [brew("php", "8.4.1")])], depth: .deep)
        let after = makeSnapshot(tools: [nodeTool(fast), tool("php", "PHP", [unprobed])], at: t1, depth: .fast)
        #expect(SnapshotDiffer().changes(from: before, to: after).isEmpty)
    }

    @Test func toolsAndInstallationsAddedAndRemoved() {
        let before = makeSnapshot(tools: [
            tool("php", "PHP", [brew("php", "8.4.1")]),
            tool("go", "Go", [brew("go", "1.26.0")]),
        ])
        let after = makeSnapshot(tools: [
            tool("php", "PHP", [brew("php", "8.4.1"), brew("php@8.2", "8.2.29", linkState: .notOnPath)]),
            tool("deno", "Deno", [brew("deno", "2.9.6")]),
        ], at: t1)
        let changes = SnapshotDiffer().changes(from: before, to: after)
        #expect(Set(changes.map(\.kind)) == [.toolAdded, .toolRemoved, .installationAdded])
        #expect(changes.first { $0.kind == .toolAdded }?.toolID == "deno")
        #expect(changes.first { $0.kind == .toolAdded }?.to == "2.9.6")
        #expect(changes.first { $0.kind == .toolRemoved }?.from == "1.26.0")
        #expect(changes.first { $0.kind == .installationAdded }?.installationID == "homebrew:php@8.2")
    }

    @Test func versionManagedSwapIsOneVersionChange() throws {
        let v22 = path("/Users/tester/.nvm/versions/node/v22.1.0/bin/node", "22.1.0", provider: .nvm)
        let v24 = path("/Users/tester/.nvm/versions/node/v24.3.0/bin/node", "24.3.0", provider: .nvm)
        let changes = SnapshotDiffer().changes(from: makeSnapshot(tools: [nodeTool(v22)]), to: makeSnapshot(tools: [nodeTool(v24)], at: t1))
        let change = try #require(changes.first)
        #expect(changes.count == 1)
        #expect(change.kind == .versionChanged)
        #expect(change.from == "22.1.0" && change.to == "24.3.0")
    }

    @Test func movingToAnotherProviderIsAProviderChange() throws {
        let npm = ToolInstallation(id: "npm@/opt/homebrew/lib/node_modules:@anthropic-ai/claude-code", ownership: Ownership(provider: .npm, confidence: .confirmed), version: observed("2.1.200"), executables: [ExecutableRef(name: "claude", path: "/opt/homebrew/bin/claude", pathPriority: 11)], linkState: .active)
        let native = ToolInstallation(id: "path:/Users/tester/.local/bin/claude", ownership: Ownership(provider: .native, confidence: .confirmed), version: observed("2.1.234"), executables: [ExecutableRef(name: "claude", path: "/Users/tester/.local/bin/claude", pathPriority: 10)], linkState: .active)
        let changes = SnapshotDiffer().changes(
            from: makeSnapshot(tools: [tool("claude-code", "Claude Code", [npm], command: "claude")]),
            to: makeSnapshot(tools: [tool("claude-code", "Claude Code", [native], command: "claude")], at: t1)
        )
        let change = try #require(changes.first)
        #expect(changes.count == 1)
        #expect(change.kind == .providerChanged)
        #expect(change.previousProvider == .npm && change.provider == .native)
        #expect(change.from == "2.1.200" && change.to == "2.1.234")
    }

    @Test func activeExecutableChangeWhenAnotherInstallationWins() throws {
        var standalone = path("/Users/tester/.local/bin/node", "26.2.0", provider: .standalone)
        var homebrew = brew("node", "26.7.0", linkState: .shadowed)
        homebrew.executables[0].pathPriority = 11
        standalone.executables[0].pathPriority = 10
        let before = nodeTool(standalone, others: [homebrew])
        standalone.linkState = .shadowed
        homebrew.linkState = .active
        var after = nodeTool(homebrew, others: [standalone])
        after.resolution = CommandResolution(command: "node", chain: [homebrew.executables[0], standalone.executables[0]])
        after.resolution?.chain[1].pathPriority = 12

        let changes = SnapshotDiffer().changes(from: makeSnapshot(tools: [before]), to: makeSnapshot(tools: [after], at: t1))
        let change = try #require(changes.first { $0.kind == .activeExecutableChanged })
        #expect(changes.count == 1)
        #expect(change.subject == "node")
        #expect(change.from == "/Users/tester/.local/bin/node")
        #expect(change.to == "/opt/homebrew/bin/node")
        #expect(change.previousProvider == .standalone && change.provider == .homebrew)
    }

    @Test func failedProviderDoesNotLookLikeRemovals() {
        let before = makeSnapshot(tools: [tool("gh", "GitHub CLI", [brew("gh", "2.92.0")]), nodeTool(brew("node", "24.1.0"), others: [path("/Users/tester/.local/bin/node", "26.2.0", provider: .standalone)])])
        var after = makeSnapshot(tools: [nodeTool(path("/Users/tester/.local/bin/node", "26.2.0", provider: .standalone))], at: t1)
        after.providers = [ProviderSnapshot(providerID: .homebrew, availability: ProviderAvailability(providerID: .homebrew, isAvailable: true), freshness: .unavailable, lastError: "brew info timed out")]
        let changes = SnapshotDiffer().changes(from: before, to: after)
        #expect(!changes.contains { $0.kind == .toolRemoved || $0.kind == .installationRemoved })
    }

    @Test func unrecognizedChurnCollapsesIntoACount() throws {
        let helpers = (1...8).map { index in
            tool("unknown.\(index)", "helper\(index)", [path("/Applications/Tool.app/bin/helper\(index)", nil, provider: .standalone, confidence: .unknown)], category: .unrecognized, command: "helper\(index)")
        }
        let few = Array(helpers.prefix(2))
        let base = [nodeTool(brew("node", "24.1.0"))]
        let many = SnapshotDiffer().changes(from: makeSnapshot(tools: base), to: makeSnapshot(tools: base + helpers, at: t1))
        let collapsed = try #require(many.first)
        #expect(many.count == 1)
        #expect(collapsed.kind == .unrecognizedToolsAdded)
        #expect(collapsed.count == 8)
        #expect(collapsed.names.count == 5)

        let individual = SnapshotDiffer().changes(from: makeSnapshot(tools: base + helpers), to: makeSnapshot(tools: base + helpers.dropLast(6), at: t1))
        #expect(individual.map(\.kind) == [.unrecognizedToolsRemoved])
        let small = SnapshotDiffer().changes(from: makeSnapshot(tools: base), to: makeSnapshot(tools: base + few, at: t1))
        #expect(small.map(\.kind) == [.toolAdded, .toolAdded])
    }

    // MARK: PATH and services

    @Test func pathEntriesAddedRemovedAndMoved() {
        let before = makeSnapshot(path: ["/Users/tester/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/old/bin"])
        // `/opt/homebrew/bin` jumps to the front; the rest keep their relative order.
        let after = makeSnapshot(path: ["/opt/homebrew/bin", "/Users/tester/.local/bin", "/usr/local/bin", "/Users/tester/.bun/bin", "/usr/bin", "/opt/homebrew/bin"], at: t1)
        let changes = SnapshotDiffer().changes(from: before, to: after)
        #expect(changes.filter { $0.kind == .pathEntryAdded }.map(\.subject) == ["/Users/tester/.bun/bin"])
        #expect(changes.filter { $0.kind == .pathEntryRemoved }.map(\.subject) == ["/old/bin"])
        let moved = changes.filter { $0.kind == .pathEntryMoved }
        #expect(moved.count == 1)
        #expect(moved.first?.from == "2" && moved.first?.to == "1")
    }

    @Test func fallbackShellPathIsNotAPathChange() {
        let before = makeSnapshot(path: ["/Users/tester/.local/bin", "/opt/homebrew/bin", "/usr/bin"])
        var after = makeSnapshot(path: ["/usr/bin", "/bin"], at: t1)
        after.shell.source = .fallback
        #expect(SnapshotDiffer().changes(from: before, to: after).isEmpty)
    }

    @Test func servicesStartAndStop() {
        func service(_ status: ServiceStatus) -> ToolService {
            ToolService(id: "homebrew:postgresql@17", name: "postgresql@17", providerID: .homebrew, status: status, toolID: "postgresql")
        }
        let tools = [tool("postgresql", "PostgreSQL", [brew("postgresql@17", "17.10")], command: "psql")]
        var before = makeSnapshot(tools: tools)
        before.services = [service(.stopped)]
        var after = makeSnapshot(tools: tools, at: t1)
        after.services = [service(.running)]
        #expect(SnapshotDiffer().changes(from: before, to: after).map(\.kind) == [.serviceStarted])
        #expect(SnapshotDiffer().changes(from: after, to: before).map(\.kind) == [.serviceStopped])
        before.services = [service(.unknown)]
        #expect(SnapshotDiffer().changes(from: before, to: after).isEmpty)
    }

    // MARK: Attribution

    @Test func updateRunByCLIStateIsAttributed() throws {
        let change = EnvironmentChange(kind: .versionChanged, toolID: "node", installationID: "homebrew:node", provider: .homebrew, from: "24.1.0", to: "24.2.0")
        let dependency = EnvironmentChange(kind: .versionChanged, toolID: "homebrew.libuv", category: .dependency, installationID: "homebrew:libuv", provider: .homebrew, from: "1.50", to: "1.51")
        let unrelated = EnvironmentChange(kind: .versionChanged, toolID: "gh", installationID: "homebrew:gh", provider: .homebrew, from: "2.91.0", to: "2.92.0")
        let entry = CommandHistoryEntry(
            planKind: .update, providerID: .homebrew, commands: ["brew upgrade node"],
            targets: [OperationTarget(toolID: "node", installationID: "homebrew:node", packageName: "node", displayName: "Node.js", fromVersion: "24.1.0", toVersion: "24.2.0")],
            status: .running, startedAt: t0.addingTimeInterval(600)
        )
        let result = ChangeAttributor().attribute([change, dependency, unrelated], history: [entry], since: t0, until: t1)
        #expect(result[0].origin.kind == .clistate)
        #expect(result[0].origin.historyEntryID == entry.id)
        #expect(result[0].origin.operation == .update)
        #expect(result[1].origin.kind == .clistate)
        #expect(result[2].origin.kind == .external)
    }

    @Test func operationsOutsideTheScanWindowOrOfAnotherKindDontCount() {
        let removal = EnvironmentChange(kind: .installationRemoved, toolID: "node", installationID: "homebrew:node", provider: .homebrew, from: "24.1.0")
        let target = OperationTarget(toolID: "node", installationID: "homebrew:node", packageName: "node", displayName: "Node.js")
        let old = CommandHistoryEntry(planKind: .uninstall, providerID: .homebrew, commands: [], targets: [target], status: .succeeded, startedAt: t0.addingTimeInterval(-7200), finishedAt: t0.addingTimeInterval(-7100))
        let later = CommandHistoryEntry(planKind: .uninstall, providerID: .homebrew, commands: [], targets: [target], status: .succeeded, startedAt: t1.addingTimeInterval(60), finishedAt: t1.addingTimeInterval(70))
        let wrongKind = CommandHistoryEntry(planKind: .service(.restart), providerID: .homebrew, commands: [], targets: [target], status: .succeeded, startedAt: t0.addingTimeInterval(60), finishedAt: t0.addingTimeInterval(70))
        let result = ChangeAttributor().attribute([removal], history: [old, later, wrongKind], since: t0, until: t1)
        #expect(result[0].origin == .external)

        let matching = CommandHistoryEntry(planKind: .uninstall, providerID: .homebrew, commands: [], targets: [target], status: .succeeded, startedAt: t0.addingTimeInterval(-30), finishedAt: t0.addingTimeInterval(30))
        #expect(ChangeAttributor().attribute([removal], history: [matching], since: t0, until: t1)[0].origin.kind == .clistate)
    }

    // MARK: Preferences

    @Test func toolPoliciesFollowAPackageIntoTheRegistry() throws {
        let snapshot = makeSnapshot(tools: [tool("cocoapods", "CocoaPods", [brew("cocoapods", "1.17.0")])])
        let preferences = UpdatePreferences(toolPolicies: ["homebrew.cocoapods": .automatic, "homebrew.gone": .notify, "cocoapods-legacy": .off])
        let migrated = try #require(preferences.migratingToolIDs(in: snapshot))
        #expect(migrated.toolPolicies == ["cocoapods": .automatic, "homebrew.gone": .notify, "cocoapods-legacy": .off])
        #expect(migrated.migratingToolIDs(in: snapshot) == nil)
        // An explicit policy on the new ID wins over the old one.
        let both = UpdatePreferences(toolPolicies: ["homebrew.cocoapods": .automatic, "cocoapods": .off])
        #expect(both.migratingToolIDs(in: snapshot) == nil)
    }

    @Test func brewUpdateExplainsHomebrewsOwnVersionOnly() {
        let brew = EnvironmentChange(kind: .versionChanged, toolID: "homebrew", installationID: "native:homebrew", provider: .homebrew, from: "6.0.22", to: "6.0.22-325-g06cc132")
        let formula = EnvironmentChange(kind: .versionChanged, toolID: "node", installationID: "homebrew:node", provider: .homebrew, from: "24.1.0", to: "24.2.0")
        let entry = CommandHistoryEntry(planKind: .refreshMetadata, providerID: .homebrew, commands: ["brew update"], targets: [], status: .succeeded, startedAt: t0.addingTimeInterval(10), finishedAt: t0.addingTimeInterval(30))
        let result = ChangeAttributor().attribute([brew, formula], history: [entry], since: t0, until: t1)
        #expect(result[0].origin.operation == .refreshMetadata)
        #expect(result[1].origin == .external, "brew update never upgrades formulae")
    }

    @Test func installFromRestoreIsAttributed() {
        let added = EnvironmentChange(kind: .toolAdded, toolID: "pipx", installationID: "homebrew:pipx", provider: .homebrew, to: "1.8.0")
        let entry = CommandHistoryEntry(
            planKind: .install, providerID: .homebrew, commands: ["brew install pipx"],
            targets: [OperationTarget(toolID: "pipx", packageName: "pipx", displayName: "pipx")],
            status: .succeeded, startedAt: t0.addingTimeInterval(5), finishedAt: t0.addingTimeInterval(60)
        )
        let result = ChangeAttributor().attribute([added], history: [entry], since: t0, until: t1)
        #expect(result[0].origin.kind == .clistate)
        #expect(result[0].origin.operation == .install)
    }

    @Test func moveToTrashMatchesByPath() {
        let change = EnvironmentChange(kind: .toolRemoved, toolID: "unknown.abc", installationID: .path("/Users/tester/.local/bin/mavis"), from: nil)
        let entry = CommandHistoryEntry(
            planKind: .moveToTrash, providerID: .standalone, commands: ["Move to Trash: /Users/tester/.local/bin/mavis"],
            targets: [OperationTarget(packageName: "/Users/tester/.local/bin/mavis", displayName: "mavis")],
            status: .succeeded, startedAt: t0.addingTimeInterval(5), finishedAt: t0.addingTimeInterval(6)
        )
        #expect(ChangeAttributor().attribute([change], history: [entry], since: t0, until: t1)[0].origin.kind == .clistate)
    }

    @Test func servicePlansMatchByServiceName() {
        let change = EnvironmentChange(kind: .serviceStarted, toolID: "caddy", provider: .homebrew, subject: "caddy")
        let entry = CommandHistoryEntry(planKind: .service(.start), providerID: .homebrew, commands: ["brew services start caddy"], targets: [OperationTarget(packageName: "caddy", displayName: "caddy")], status: .succeeded, startedAt: t0.addingTimeInterval(5), finishedAt: t0.addingTimeInterval(9))
        #expect(ChangeAttributor().attribute([change], history: [entry], since: t0, until: t1)[0].origin.kind == .clistate)
    }

    @Test func changeRowsDecodeTolerantly() throws {
        let json = Data("""
        {"id":"8B1B0F52-8E7A-4A4B-9D57-9C0A3C1B2D11","detectedAt":"2026-09-13T08:00:00Z","depth":"fast","changes":[
          {"kind":"versionChanged","toolID":"node","from":"24.1.0","to":"24.2.0","category":"futureCategory","origin":{"kind":"somethingNew"}},
          {"kind":"teleported","toolID":"php"},
          {"kind":"pathEntryAdded","subject":"/opt/homebrew/bin","to":"1"}
        ]}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(EnvironmentChangeEvent.self, from: json)
        #expect(event.changes.map(\.kind) == [.versionChanged, .pathEntryAdded])
        #expect(event.changes[0].category == nil)
        #expect(event.changes[0].origin == .external)
        #expect(event.isBaseline == false)
    }
}

// MARK: - Builders

private func observed(_ version: String) -> ObservedValue<ToolVersion> {
    ObservedValue(ToolVersion(version), source: .provider(.homebrew), confidence: .confirmed, observedAt: t0)
}

private func brew(_ formula: String, _ version: String, linkState: LinkState = .active) -> ToolInstallation {
    let command = formula.split(separator: "@").first.map(String.init) ?? formula
    return ToolInstallation(
        id: .package(provider: .homebrew, name: formula),
        ownership: Ownership(provider: .homebrew, packageName: formula, confidence: .confirmed),
        version: observed(version),
        executables: [ExecutableRef(name: command, path: "/opt/homebrew/bin/\(command)", resolvedPath: "/opt/homebrew/Cellar/\(formula)/\(version)/bin/\(command)", pathPriority: linkState == .notOnPath ? nil : 11)],
        installPrefix: "/opt/homebrew/Cellar/\(formula)/\(version)",
        linkState: linkState
    )
}

private func path(_ executable: String, _ version: String?, provider: ProviderID, confidence: AttributionConfidence = .probable) -> ToolInstallation {
    ToolInstallation(
        id: .path(executable),
        ownership: Ownership(provider: provider, confidence: confidence),
        version: version.map(observed),
        executables: [ExecutableRef(name: (executable as NSString).lastPathComponent, path: executable, pathPriority: 10)],
        linkState: .active
    )
}

private func tool(_ id: ToolID, _ name: String, _ installations: [ToolInstallation], category: ToolCategory = .runtime, command: String? = nil, scannedAt: Date = t0) -> Tool {
    let active = installations.first { $0.linkState == .active } ?? installations.first
    let command = command ?? active?.executables.first?.name
    let chain = installations.flatMap(\.executables).filter { $0.name == command && $0.pathPriority != nil }.sorted { ($0.pathPriority ?? 0) < ($1.pathPriority ?? 0) }
    return Tool(
        id: id,
        identity: ToolIdentity(name: id.rawValue, displayName: name, category: category, registryID: id.rawValue),
        installations: installations,
        activeInstallationID: active?.id,
        resolution: command.map { CommandResolution(command: $0, chain: chain) },
        health: ToolHealthState(status: .healthy),
        lastScannedAt: scannedAt
    )
}

private func nodeTool(_ active: ToolInstallation, others: [ToolInstallation] = [], scannedAt: Date = t0) -> Tool {
    var result = tool("node", "Node.js", [active] + others, command: "node", scannedAt: scannedAt)
    result.activeInstallationID = active.id
    return result
}

private func makeSnapshot(tools: [Tool] = [], path: [String] = ["/opt/homebrew/bin", "/usr/bin"], at date: Date = t0, depth: ScanDepth = .fast) -> EnvironmentSnapshot {
    var seen = Set<String>()
    let entries = path.enumerated().map { index, entry in
        let duplicate = !seen.insert(entry).inserted
        return PATHEntry(priority: index + 1, rawValue: entry, normalizedPath: entry, status: duplicate ? .duplicate : .ok, source: .unknown)
    }
    return EnvironmentSnapshot(
        capturedAt: date,
        depth: depth,
        shell: ShellEnvironment(shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh), path: path, variables: [:], source: .loginShell, capturedAt: date),
        pathEntries: entries,
        brokenSymlinks: [],
        providers: [ProviderSnapshot(providerID: .homebrew, availability: ProviderAvailability(providerID: .homebrew, isAvailable: true), freshness: .fresh(date))],
        tools: tools,
        services: [],
        issues: []
    )
}
