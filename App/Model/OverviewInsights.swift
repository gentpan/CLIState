import CLIStateDomain
import Foundation

enum InstallationGroup: String, CaseIterable, Identifiable {
    case system, officialInstaller, direct, dependency, unknown
    var id: Self { self }

    static func classify(_ installation: ToolInstallation) -> Self {
        if installation.isSystemManaged || installation.ownership.provider == .system { return .system }
        guard installation.ownership.permitsMutation else { return .unknown }
        if installation.ownership.provider == .native { return .officialInstaller }
        if installation.isDirect == true { return .direct }
        if installation.isDirect == false { return .dependency }
        return .unknown
    }
}

enum UsageRecency: String, CaseIterable, Identifiable {
    case week, month, quarter, older, unknown
    var id: Self { self }

    static func classify(_ tool: Tool, now: Date) -> Self {
        guard let date = tool.installations.compactMap(\.lastUsedAt).max(), date <= now else { return .unknown }
        let age = now.timeIntervalSince(date) / 86_400
        if age <= 7 { return .week }
        if age <= 30 { return .month }
        if age <= 90 { return .quarter }
        return .older
    }
}

enum ToolActionsAvailable {
    static func canUninstall(_ installation: ToolInstallation) -> Bool {
        installation.capabilities.canUninstall && installation.ownership.permitsMutation
            && !installation.isSystemManaged && installation.ownership.provider != .system
    }

    static func canUpdate(_ installation: ToolInstallation) -> Bool {
        installation.capabilities.canUpdate && installation.ownership.permitsMutation
            && !installation.isSystemManaged && installation.ownership.provider != .system
    }
}

struct VersionTrend {
    struct Day: Identifiable {
        var date: Date
        var count: Int
        var id: Date { date }
    }
    struct Change: Identifiable {
        var id: String
        var date: Date
        var value: EnvironmentChange
    }

    let days: [Day]
    let changes: [Change]

    init(events: [EnvironmentChangeEvent], visibleIDs: Set<ToolID>, window: Int, now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(window - 1), to: today) ?? today
        let recorded = events.filter { $0.detectedAt <= now }
        guard let first = recorded.map(\.detectedAt).min() else {
            days = []; changes = []; return
        }
        let coverage = max(start, calendar.startOfDay(for: first))
        var seen: Set<String> = []
        changes = recorded.filter { !$0.isBaseline }.flatMap { event in
            event.changes.compactMap { change -> Change? in
                let id = "\(event.id)|\(change.id)"
                guard event.detectedAt >= coverage, change.kind == .versionChanged,
                      let toolID = change.toolID, visibleIDs.contains(toolID), seen.insert(id).inserted
                else { return nil }
                return Change(id: id, date: event.detectedAt, value: change)
            }
        }.sorted { $0.date > $1.date }
        let counts = Dictionary(grouping: changes) { calendar.startOfDay(for: $0.date) }.mapValues(\.count)
        var points: [Day] = []
        var date = coverage
        while date <= today {
            points.append(Day(date: date, count: counts[date, default: 0]))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = next
        }
        days = points
    }
}
