import CLIStateDomain
import Foundation
import Testing

@Suite("Overview data integrity")
struct OverviewInsightsTests {
    private func installation(provider: ProviderID = .homebrew, confirmed: Bool = true, system: Bool = false) -> ToolInstallation {
        ToolInstallation(id: "test", ownership: Ownership(provider: provider, confidence: confirmed ? .confirmed : .probable), linkState: .active, isSystemManaged: system, capabilities: ToolCapabilities(canUpdate: true, canUninstall: true))
    }

    @Test func protectedAndUnconfirmedCopiesNeverOfferWrites() {
        for item in [installation(system: true), installation(provider: .system), installation(confirmed: false)] {
            #expect(!ToolActionsAvailable.canUpdate(item))
            #expect(!ToolActionsAvailable.canUninstall(item))
        }
        #expect(ToolActionsAvailable.canUninstall(installation()))
        #expect(InstallationGroup.classify(installation(provider: .native, confirmed: false)) == .unknown)
        #expect(InstallationGroup.classify(installation(provider: .native)) == .officialInstaller)
    }

    @Test func unknownUseIsNotLowUse() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var item = installation()
        func tool(_ value: ToolInstallation) -> Tool {
            Tool(id: "test", identity: ToolIdentity(name: "test", displayName: "Test", category: .developerTool), installations: [value], health: ToolHealthState(status: .healthy), lastScannedAt: now)
        }
        #expect(UsageRecency.classify(tool(item), now: now) == .unknown)
        item.lastUsedAt = now.addingTimeInterval(-100 * 86_400)
        #expect(UsageRecency.classify(tool(item), now: now) == .older)
        item.lastUsedAt = now.addingTimeInterval(60)
        #expect(UsageRecency.classify(tool(item), now: now) == .unknown)
    }

    @Test func trendUsesObservedDaysAndDeduplicatesEvents() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_999_987_200)
        let baseline = EnvironmentChangeEvent(detectedAt: now.addingTimeInterval(-86_400), depth: .fast, isBaseline: true, changes: [])
        let event = EnvironmentChangeEvent(detectedAt: now, depth: .fast, changes: [EnvironmentChange(kind: .versionChanged, toolID: "test", from: "2", to: "1"), EnvironmentChange(kind: .toolAdded, toolID: "test")])
        let trend = VersionTrend(events: [event, baseline, event], visibleIDs: ["test"], window: 30, now: now, calendar: calendar)
        #expect(trend.days.count == 2)
        #expect(trend.days.map(\.count) == [0, 1])
        #expect(trend.changes.count == 1)
        #expect(VersionTrend(events: [], visibleIDs: [], window: 7).days.isEmpty)
    }
}
