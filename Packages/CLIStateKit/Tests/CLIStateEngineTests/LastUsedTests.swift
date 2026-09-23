import CLIStateDomain
@testable import CLIStateEngine
import CLIStateTestSupport
import Foundation
import Testing

@Suite("Last used")
struct LastUsedTests {
    private let keg = "/opt/homebrew/Cellar/jq/1.8.1"
    private var jqPath: String { "\(keg)/bin/jq" }
    private let yesterday = scanDate.addingTimeInterval(-24 * 3600)

    private func jqScenario() -> (EngineScenario, ProviderInventory) {
        let scenario = EngineScenario()
        scenario.fs.addFile(jqPath, contents: Data(count: 100), executable: true, modifiedAt: scanDate.addingTimeInterval(-90 * 24 * 3600))
        scenario.link("/opt/homebrew/bin/jq", to: "../Cellar/jq/1.8.1/bin/jq")
        return (scenario, homebrewInventory([formula("jq", "1.8.1", executables: ["jq"])]))
    }

    private func installation(_ snapshot: EnvironmentSnapshot, _ id: InstallationID) -> ToolInstallation? {
        snapshot.tools.lazy.flatMap(\.installations).first { $0.id == id }
    }

    private func jq(_ snapshot: EnvironmentSnapshot) -> ToolInstallation? {
        installation(snapshot, .package(provider: .homebrew, name: "jq"))
    }

    @Test func accessTimeOfThePrimaryExecutable() async throws {
        let (scenario, inventory) = jqScenario()
        scenario.fs.setAccessedAt(jqPath, yesterday)
        let snapshot = await scenario.build(inventories: [inventory])
        #expect(jq(snapshot)?.lastUsedAt == yesterday)
    }

    @Test func notUsedSinceInstalledOrChanged() async throws {
        let (scenario, inventory) = jqScenario()
        let modified = scanDate.addingTimeInterval(-90 * 24 * 3600)
        scenario.fs.setAccessedAt(jqPath, modified)
        #expect(jq(await scenario.build(inventories: [inventory]))?.lastUsedAt == nil, "atime == mtime: copied or installed, never run")

        // Homebrew pours bottles with the archive's mtime but stamps atime and ctime with the pour time.
        let poured = scanDate.addingTimeInterval(-48 * 3600)
        scenario.fs.setStatusChangedAt(jqPath, poured.addingTimeInterval(0.5))
        scenario.fs.setAccessedAt(jqPath, poured)
        #expect(jq(await scenario.build(inventories: [inventory]))?.lastUsedAt == nil)
        scenario.fs.setAccessedAt(jqPath, poured.addingTimeInterval(30))
        #expect(jq(await scenario.build(inventories: [inventory]))?.lastUsedAt == nil, "post-install steps right after pouring aren't uses")
        scenario.fs.setAccessedAt(jqPath, poured.addingTimeInterval(3600))
        #expect(jq(await scenario.build(inventories: [inventory]))?.lastUsedAt == poured.addingTimeInterval(3600))
    }

    @Test func manyToolsAccessedInTheSameMomentAreNotUses() async throws {
        let scenario = EngineScenario()
        let names = ["jq", "fd", "bat", "eza", "yq"]
        for name in names {
            scenario.fs.addFile("/opt/homebrew/Cellar/\(name)/1.0/bin/\(name)", contents: Data(count: 10), executable: true, modifiedAt: scanDate.addingTimeInterval(-90 * 24 * 3600))
            scenario.link("/opt/homebrew/bin/\(name)", to: "../Cellar/\(name)/1.0/bin/\(name)")
        }
        let inventory = homebrewInventory(names.map { formula($0, "1.0", executables: [$0]) })
        let burst = yesterday
        for (offset, name) in names.dropLast().enumerated() {
            scenario.fs.setAccessedAt("/opt/homebrew/Cellar/\(name)/1.0/bin/\(name)", burst.addingTimeInterval(Double(offset) * 0.4))
        }
        scenario.fs.setAccessedAt("/opt/homebrew/Cellar/yq/1.0/bin/yq", burst.addingTimeInterval(-3600))
        let snapshot = await scenario.build(inventories: [inventory])
        for name in names.dropLast() {
            #expect(installation(snapshot, .package(provider: .homebrew, name: name))?.lastUsedAt == nil, "\(name) was run by a script")
        }
        #expect(installation(snapshot, .package(provider: .homebrew, name: "yq"))?.lastUsedAt == burst.addingTimeInterval(-3600))
    }

    @Test func systemManagedInstallationsHaveNoLastUse() async throws {
        let scenario = EngineScenario()
        scenario.executable("/usr/bin/python3")
        scenario.runner.stub("python3", ["--version"], stdout: "Python 3.9.6\n")
        scenario.fs.setAccessedAt("/usr/bin/python3", yesterday)
        let snapshot = await scenario.build()
        let system = try #require(snapshot.tool("python")?.installation("path:/usr/bin/python3"))
        #expect(system.isSystemManaged)
        #expect(system.lastUsedAt == nil)
        #expect(system.diskUsage == nil)
    }

    @Test func accessesDuringThisScanAreCLIStates() async throws {
        let (scenario, inventory) = jqScenario()
        // e.g. a provider ran the tool while scanning, seconds before the engine started.
        scenario.fs.setAccessedAt(jqPath, scanDate.addingTimeInterval(-3))
        #expect(jq(await scenario.build(inventories: [inventory]))?.lastUsedAt == nil)

        scenario.fs.setAccessedAt(jqPath, yesterday)
        let first = await scenario.build(inventories: [inventory])
        let later = scanDate.addingTimeInterval(6 * 3600)
        scenario.fs.setAccessedAt(jqPath, later.addingTimeInterval(-4))
        let second = await scenario.build(inventories: [homebrewInventory([formula("jq", "1.8.1", executables: ["jq"])], at: later)], previous: first, now: later)
        #expect(jq(second)?.lastUsedAt == yesterday, "keeps the previous use")
    }

    @Test func versionProbesAreNotUses() async throws {
        let scenario = EngineScenario()
        let binary = "\(home)/.local/share/claude/versions/2.1.234"
        scenario.fs.addFile(binary, contents: Data("claude".utf8), executable: true, modifiedAt: scanDate.addingTimeInterval(-30 * 24 * 3600))
        scenario.link("\(home)/.local/bin/claude", to: binary)
        scenario.runner.stub("claude", ["--version"], stdout: "2.1.234 (Claude Code)\n")
        scenario.fs.setAccessedAt(binary, yesterday)

        // A long deep scan: the probe runs five minutes after the capture time.
        let probedAt = scanDate.addingTimeInterval(300)
        let first = await scenario.build(depth: .deep, updateSources: [StubUpdateSource(result: nil)], clock: { probedAt })
        let id: InstallationID = .path("\(home)/.local/bin/claude")
        #expect(installation(first, id)?.lastUsedAt == yesterday)
        #expect(first.versionCache[binary]?.probedAt == probedAt)
        #expect(scenario.probedNames.filter { $0 == "claude" }.count == 1)

        // The probe itself updated the access time.
        scenario.fs.setAccessedAt(binary, probedAt.addingTimeInterval(2))
        let later = scanDate.addingTimeInterval(3600)
        let second = await scenario.build(previous: first, now: later)
        #expect(installation(second, id)?.lastUsedAt == yesterday)
        #expect(second.versionCache[binary]?.probedAt == probedAt, "a cached probe keeps its time")
        #expect(scenario.probedNames.filter { $0 == "claude" }.count == 1, "no second probe")

        // A third scan still knows the probe time, and a real use afterwards counts.
        let third = await scenario.build(previous: second, now: later.addingTimeInterval(3600))
        #expect(installation(third, id)?.lastUsedAt == yesterday)
        scenario.fs.setAccessedAt(binary, probedAt.addingTimeInterval(600))
        let used = await scenario.build(previous: first, now: later)
        #expect(installation(used, id)?.lastUsedAt == probedAt.addingTimeInterval(600))
    }

    @Test func accessesThePreviousScanAlreadyJudgedKeepItsVerdict() async throws {
        let (scenario, inventory) = jqScenario()
        scenario.fs.setAccessedAt(jqPath, scanDate.addingTimeInterval(-2))
        let first = await scenario.build(inventories: [inventory])
        #expect(jq(first)?.lastUsedAt == nil)
        #expect(jq(first)?.diskUsage != nil, "the snapshot recorded usage")

        // Hours later the access time is unchanged: still CLI State's, not a use.
        let later = scanDate.addingTimeInterval(5 * 3600)
        let second = await scenario.build(inventories: [homebrewInventory([formula("jq", "1.8.1", executables: ["jq"])], at: later)], previous: first, now: later)
        #expect(jq(second)?.lastUsedAt == nil)
    }

    @Test func aReplacedExecutableDropsTheOldUse() async throws {
        let (scenario, inventory) = jqScenario()
        scenario.fs.setAccessedAt(jqPath, yesterday)
        let first = await scenario.build(inventories: [inventory])
        #expect(jq(first)?.lastUsedAt == yesterday)

        // Reinstalled in place an hour ago; the access time now is CLI State's own.
        let later = scanDate.addingTimeInterval(3600)
        scenario.fs.addFile(jqPath, contents: Data(count: 120), executable: true, modifiedAt: later.addingTimeInterval(-3600))
        scenario.fs.setAccessedAt(jqPath, later.addingTimeInterval(-3))
        let second = await scenario.build(inventories: [homebrewInventory([formula("jq", "1.8.1", executables: ["jq"])], at: later)], previous: first, now: later)
        #expect(jq(second)?.lastUsedAt == nil)
    }

    @Test func activityWindowIgnoresStaleEnvironmentTimes() {
        let discovery = EngineScenario().discovery()
        let now = scanDate.addingTimeInterval(8 * 3600)
        let activity = UsageActivity(discovery: discovery, inventories: [], previous: nil, now: now, evaluatedAt: now)
        #expect(!activity.isOwnAccess(scanDate.addingTimeInterval(3600), paths: ["/x"]), "the shell environment was captured hours ago")
        #expect(activity.isOwnAccess(now.addingTimeInterval(-60), paths: ["/x"]))
    }
}
