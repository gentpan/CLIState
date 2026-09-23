import CLIStateDomain
@testable import CLIStateEngine
import CLIStateTestSupport
import Foundation
import Testing

@Suite("Latest-version carry-forward")
struct LatestVersionCarryForwardTests {
    private let root = "/opt/homebrew/lib/node_modules"
    private let deepDate = scanDate
    private let launchDate = scanDate.addingTimeInterval(2 * 3600)

    private func npm(_ version: String, latest: String? = nil, depth: ScanDepth, at date: Date) -> ProviderInventory {
        npmInventory(root: root, [npmPackage("left-pad", version, latest: latest)], depth: depth, at: date)
    }

    private func leftPad(_ snapshot: EnvironmentSnapshot) -> ToolInstallation? {
        snapshot.tools.lazy.flatMap(\.installations).first { $0.ownership.packageName == "left-pad" }
    }

    @Test func deepScanRecordsCheckTimeAndFastScanKeepsIt() async throws {
        let scenario = EngineScenario()
        let deep = await scenario.build(inventories: [npm("1.0.0", latest: "1.3.0", depth: .deep, at: deepDate)], depth: .deep, updateSources: [StubUpdateSource(result: nil)], now: deepDate)
        #expect(deep.latestCheckedAt == deepDate)

        let fast = await scenario.build(inventories: [npm("1.0.0", depth: .fast, at: launchDate)], previous: deep, depth: .fast, now: launchDate)
        #expect(fast.latestCheckedAt == deepDate, "fast scans never count as a check")
        let carried = try #require(leftPad(fast))
        #expect(carried.latest?.value.rawValue == "1.3.0")
        #expect(carried.latest?.observedAt == deepDate, "carried values say when they were checked")
        #expect(carried.hasUpdate)
        #expect(fast.providers.first { $0.providerID == .npm }?.latestCheckedAt == deepDate)

        // A second fast scan (e.g. after an unrelated operation) still carries the same check.
        let again = await scenario.build(inventories: [npm("1.0.0", depth: .fast, at: launchDate)], previous: fast, depth: .fast, now: launchDate.addingTimeInterval(60))
        #expect(leftPad(again)?.latest?.observedAt == deepDate)
        #expect(again.latestCheckedAt == deepDate)
    }

    @Test func changedInstalledVersionDropsCarriedLatest() async throws {
        let scenario = EngineScenario()
        let deep = await scenario.build(inventories: [npm("1.0.0", latest: "1.3.0", depth: .deep, at: deepDate)], depth: .deep, updateSources: [StubUpdateSource(result: nil)], now: deepDate)
        let upgraded = await scenario.build(inventories: [npm("1.2.0", depth: .fast, at: launchDate)], previous: deep, depth: .fast, now: launchDate)
        let installation = try #require(leftPad(upgraded))
        #expect(installation.version?.value.rawValue == "1.2.0")
        #expect(installation.latest == nil)
        #expect(!installation.hasUpdate)
    }

    @Test func fastScanDataWinsOverCarriedValue() async throws {
        let scenario = EngineScenario()
        let deep = await scenario.build(inventories: [npm("1.0.0", latest: "1.3.0", depth: .deep, at: deepDate)], depth: .deep, updateSources: [StubUpdateSource(result: nil)], now: deepDate)
        // Homebrew-style providers know a latest version from local metadata even in fast scans.
        let fast = await scenario.build(inventories: [npm("1.0.0", latest: "1.4.0", depth: .fast, at: launchDate)], previous: deep, depth: .fast, now: launchDate)
        #expect(leftPad(fast)?.latest?.value.rawValue == "1.4.0")
        #expect(leftPad(fast)?.latest?.observedAt == launchDate)
    }

    @Test func deepScanWithFailedProviderIsNotACompletedCheck() async throws {
        let scenario = EngineScenario()
        let deep = await scenario.build(inventories: [npm("1.0.0", latest: "1.3.0", depth: .deep, at: deepDate)], depth: .deep, updateSources: [StubUpdateSource(result: nil)], now: deepDate)
        let later = deepDate.addingTimeInterval(8 * 3600)
        let failed = await scenario.build(failed: [.npm: "npm outdated timed out"], previous: deep, depth: .deep, updateSources: [StubUpdateSource(result: nil)], now: later)
        #expect(failed.latestCheckedAt == deepDate)
        #expect(LatestVersionFreshness.needsDeepCheck(failed, now: later), "a launch retries the failed check")

        let first = await scenario.build(failed: [.npm: "offline"], depth: .deep, updateSources: [StubUpdateSource(result: nil)], now: deepDate)
        #expect(first.latestCheckedAt == nil)
    }

    @Test func freshnessWindow() async throws {
        let scenario = EngineScenario()
        let deep = await scenario.build(depth: .deep, updateSources: [StubUpdateSource(result: nil)], now: deepDate)
        #expect(!LatestVersionFreshness.needsDeepCheck(deep, now: deepDate.addingTimeInterval(5 * 3600 + 59 * 60)))
        #expect(LatestVersionFreshness.needsDeepCheck(deep, now: deepDate.addingTimeInterval(6 * 3600)))
        #expect(LatestVersionFreshness.needsDeepCheck(deep, now: deepDate.addingTimeInterval(-60)), "clock moved back")
        #expect(LatestVersionFreshness.needsDeepCheck(nil, now: deepDate))
        #expect(!LatestVersionFreshness.needsDeepCheck(deep, now: deepDate.addingTimeInterval(20 * 3600), window: 24 * 3600))

        var legacy = deep
        legacy.latestCheckedAt = nil
        #expect(LatestVersionFreshness.needsDeepCheck(legacy, now: deepDate), "snapshots from older versions get one real check")
    }
}
