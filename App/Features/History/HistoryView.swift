import CLIStateDomain
import SwiftUI

/// History: the environment change timeline (default) and the operations CLIState ran.
struct HistoryView: View {
    enum Segment: String, CaseIterable, Hashable {
        case changes, operations
    }

    @Environment(AppModel.self) private var model
    @State private var segment: Segment = HistoryView.initialSegment

    var body: some View {
        Group {
            switch segment {
            case .changes: ChangeTimelineView()
            case .operations: OperationHistoryView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            header
        }
        .dsPageTitle(Text("History"), symbol: Symbol.history)
        .task(id: model.snapshot?.id) {
            await model.timeline.reload(using: model.actions, snapshotID: model.snapshot?.id)
        }
        .debugSelection { values in
            if let raw = values["history"], let selected = Segment(rawValue: raw) { segment = selected }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s3) {
            DSTabs(selection: $segment, options: Segment.allCases, title: String(localized: "Show", table: "Changes")) { segment in
                switch segment {
                case .changes: String(localized: "Changes", table: "Changes")
                case .operations: String(localized: "Operations", table: "Changes")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            Text(segment == .changes
                ? String(localized: "What changed between scans, including changes made outside CLI State.", table: "Changes")
                : String(localized: "Updates, uninstalls and other commands CLI State ran.", table: "Changes"))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(2)
            Spacer(minLength: DS.Space.s2)
            if segment == .changes {
                ChangeTimelineFilters()
            }
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s3)
        .frame(minHeight: DS.Layout.pageHeaderMinHeight)
        .background(DS.Palette.panelPrimary)
        .overlay(alignment: .bottom) { Divider() }
    }

    private static var initialSegment: Segment {
        #if DEBUG
        // `-CLIStateHistorySegment operations` for screenshots.
        if let raw = UserDefaults.standard.string(forKey: "CLIStateHistorySegment"), let segment = Segment(rawValue: raw) { return segment }
        #endif
        return .changes
    }
}

/// Commands CLIState ran, newest first.
struct OperationHistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: CommandHistoryEntry.ID?

    var body: some View {
        let entries = model.history
        Group {
            if entries.isEmpty {
                EmptyStateView("No history yet", symbol: Symbol.history, message: String(localized: "Operations that CLI State runs appear here."))
            } else {
                Table(entries, selection: $selection) {
                    TableColumn("Date") { entry in
                        Text(entry.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(DS.Font.body)
                            .dsForeground(DS.Palette.textSecondary)
                    }
                    .width(min: DS.Layout.keyColumn, ideal: DS.Layout.statColumnMin)

                    TableColumn("Operation") { entry in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(OperationText.historyTitle(entry))
                                .font(DS.Font.bodyEmphasis)
                                .dsForeground(DS.Palette.textPrimary)
                            if let target = entry.targets.first, entry.targets.count == 1, target.fromVersion != nil || target.toVersion != nil {
                                VersionChange(from: target.fromVersion, to: target.toVersion)
                            }
                            if let dependents = dependentsText(entry) {
                                // e.g. `brew upgrade php` also upgrading composer.
                                Text("Also upgraded \(dependents)")
                                    .font(DS.Font.caption)
                                    .dsForeground(DS.Palette.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .help(Text("Also upgraded \(dependents)"))
                            }
                        }
                        .padding(.vertical, DS.Space.s1)
                    }
                    .width(min: DS.Layout.statColumnMin)

                    TableColumn("Command") { entry in
                        Text(entry.commands.joined(separator: " && "))
                            .font(DS.Font.mono)
                            .dsForeground(DS.Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(entry.commands.joined(separator: "\n"))
                    }
                    .width(min: DS.Layout.commandColumnMin)

                    TableColumn("Started by") { entry in
                        IconText(symbol: entry.trigger.symbol, text: entry.trigger.title, tint: DS.Palette.textSecondary, textColor: DS.Palette.textPrimary)
                    }
                    .width(min: DS.Layout.keyColumn, ideal: DS.Layout.keyColumn)

                    TableColumn("Result") { entry in
                        VStack(alignment: .leading, spacing: 0) {
                            IconText(symbol: entry.status.symbol, text: entry.status.title, tint: entry.status.tint)
                            if let detail = detail(entry) {
                                Text(detail)
                                    .font(DS.Font.caption)
                                    .dsForeground(DS.Palette.textSecondary)
                            }
                        }
                    }
                    .width(min: DS.Layout.statColumnMin)
                }
                .alternatingRowBackgrounds(.disabled)
                .dsScrollBackground()
            }
        }
    }

    private func dependentsText(_ entry: CommandHistoryEntry) -> String? {
        let dependents = entry.dependents
        guard !dependents.isEmpty else { return nil }
        return dependents.map { "\($0.name) \($0.version)" }.formatted(.list(type: .and))
    }

    private func detail(_ entry: CommandHistoryEntry) -> String? {
        switch entry.status {
        case .succeeded:
            guard let finished = entry.finishedAt else { return nil }
            let duration = Duration.seconds(finished.timeIntervalSince(entry.startedAt))
            return duration.formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
        case .failed:
            return entry.exitCode.map { String(localized: "Exit code \($0)") }
        case .unverified:
            return String(localized: "Command finished, but the result couldn't be verified. Scan again to check.")
        case .running, .cancelled, .interrupted:
            return nil
        }
    }
}
