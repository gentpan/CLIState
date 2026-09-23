import CLIStateDomain
import Foundation
import Observation

/// Loaded change timeline shared by History and Tool Detail. Reloads at most
/// once per snapshot, since events are only appended by scans.
@Observable
@MainActor
final class ChangeTimelineModel {
    enum TypeFilter: String, CaseIterable, Hashable, Sendable {
        case all, versions, installs, active, providers, path, services
    }

    private(set) var events: [EnvironmentChangeEvent] = []
    private(set) var isLoaded = false
    var searchText = ""
    var typeFilter: TypeFilter = .all
    var toolFilter: ToolID?

    private var loadedSnapshotID: UUID?

    func reload(using actions: any AppActions, snapshotID: UUID?) async {
        guard !isLoaded || loadedSnapshotID != snapshotID else { return }
        loadedSnapshotID = snapshotID
        events = await actions.loadChangeEvents()
        isLoaded = true
    }

    /// One change together with the event it belongs to.
    struct Row: Identifiable, Hashable, Sendable {
        var event: EnvironmentChangeEvent.ID
        var detectedAt: Date
        var change: EnvironmentChange?
        /// Baseline rows carry no change.
        var toolCount: Int

        var id: String { "\(event.uuidString)|\(change?.id ?? "baseline")" }
    }

    struct Day: Identifiable, Hashable, Sendable {
        var date: Date
        var rows: [Row]
        var id: Date { date }
    }

    /// Filtered rows grouped by calendar day, newest first.
    func days(settings: DisplaySettings, calendar: Calendar = .current) -> [Day] {
        let filtering = typeFilter != .all || toolFilter != nil || !searchText.isEmpty
        var rows: [Row] = []
        for event in events {
            if event.isBaseline {
                if !filtering { rows.append(Row(event: event.id, detectedAt: event.detectedAt, toolCount: event.toolCount)) }
                continue
            }
            for change in event.changes where isVisible(change, settings: settings) && matches(change) {
                rows.append(Row(event: event.id, detectedAt: event.detectedAt, change: change, toolCount: event.toolCount))
            }
        }
        let grouped = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.detectedAt) }
        return grouped.keys.sorted(by: >).map { day in
            Day(date: day, rows: grouped[day, default: []].sorted { $0.detectedAt > $1.detectedAt })
        }
    }

    /// Most recent changes for one tool, for Tool Detail.
    func recentChanges(for tool: ToolID, limit: Int = 5) -> [Row] {
        var rows: [Row] = []
        for event in events {
            for change in event.changes where change.toolID == tool {
                rows.append(Row(event: event.id, detectedAt: event.detectedAt, change: change, toolCount: event.toolCount))
                if rows.count == limit { return rows }
            }
        }
        return rows
    }

    /// Tools that appear in the timeline, for the tool filter menu.
    var toolsInTimeline: [(id: ToolID, name: String)] {
        var names: [ToolID: String] = [:]
        for change in events.flatMap(\.changes) {
            guard let id = change.toolID, names[id] == nil else { continue }
            names[id] = change.toolName ?? id.rawValue
        }
        return names.map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var hasChanges: Bool { events.contains { !$0.changes.isEmpty } }

    // MARK: Filtering

    private func isVisible(_ change: EnvironmentChange, settings: DisplaySettings) -> Bool {
        switch change.category {
        case .dependency?: settings.showDependencies
        case .unrecognized?: settings.showUnrecognized
        default: true
        }
    }

    private func matches(_ change: EnvironmentChange) -> Bool {
        if let toolFilter, change.toolID != toolFilter { return false }
        guard Self.kinds(for: typeFilter).contains(change.kind) else { return false }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        let haystack = [change.toolName, change.toolID?.rawValue, change.subject, change.from, change.to, change.provider?.displayName, change.previousProvider?.displayName]
            .compactMap { $0 } + change.names
        return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static func kinds(for filter: TypeFilter) -> Set<EnvironmentChangeKind> {
        switch filter {
        case .all: Set(EnvironmentChangeKind.allCases)
        case .versions: [.versionChanged]
        case .installs: [.toolAdded, .toolRemoved, .installationAdded, .installationRemoved, .unrecognizedToolsAdded, .unrecognizedToolsRemoved]
        case .active: [.activeExecutableChanged]
        case .providers: [.providerChanged]
        case .path: [.pathEntryAdded, .pathEntryRemoved, .pathEntryMoved]
        case .services: [.serviceStarted, .serviceStopped]
        }
    }
}
