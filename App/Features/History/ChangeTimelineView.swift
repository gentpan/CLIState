import CLIStateDomain
import SwiftUI

/// Environment change timeline: what changed between scans, grouped by day.
struct ChangeTimelineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var timeline = model.timeline
        let days = timeline.days(settings: model.displaySettings)
        Group {
            if !timeline.isLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if days.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.s6) {
                        ForEach(days) { day in
                            VStack(alignment: .leading, spacing: DS.Space.s2) {
                                dayHeader(day)
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(day.rows.enumerated()), id: \.element.id) { index, row in
                                        ChangeRow(row: row)
                                        if index < day.rows.count - 1 { Divider() }
                                    }
                                }
                                .dsCard(padding: DS.Space.s2)
                            }
                        }
                    }
                    .padding(DS.Space.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .dsScrollBackground()
            }
        }
        .searchable(text: $timeline.searchText, placement: .toolbar, prompt: Text("Tool, version, path or provider", tableName: "Changes"))
    }

    private func dayHeader(_ day: ChangeTimelineModel.Day) -> some View {
        HStack(spacing: DS.Space.s2) {
            Text(ChangeText.dayTitle(day.date))
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            let count = day.rows.filter { $0.change != nil }.count
            if count > 0 {
                Text("\(count) changes", tableName: "Changes")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.timeline.typeFilter != .all || model.timeline.toolFilter != nil || !model.timeline.searchText.isEmpty {
            ContentUnavailableView {
                Label { Text("No matching changes", tableName: "Changes") } icon: { Image(systemName: Symbol.search) }
            } actions: {
                Button {
                    model.timeline.typeFilter = .all
                    model.timeline.toolFilter = nil
                    model.timeline.searchText = ""
                } label: {
                    Text("Clear Filters", tableName: "Changes")
                }
            }
        } else {
            ContentUnavailableView {
                Label { Text("No changes yet", tableName: "Changes") } icon: { Image(systemName: Symbol.history) }
            } description: {
                Text("CLI State compares each scan with the previous one. Installs, updates and PATH changes appear here.", tableName: "Changes")
            }
        }
    }
}

// MARK: - Filters

/// Type and tool menus shown in the History header while the timeline is selected.
struct ChangeTimelineFilters: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var timeline = model.timeline
        HStack(spacing: DS.Space.s2) {
            Picker(selection: $timeline.typeFilter) {
                ForEach(ChangeTimelineModel.TypeFilter.allCases, id: \.self) { filter in
                    Text(ChangeText.filterTitle(filter)).tag(filter)
                }
            } label: {
                Label { Text("Type", tableName: "Changes") } icon: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help(Text("Filter by type of change", tableName: "Changes"))
            Picker(selection: $timeline.toolFilter) {
                Text("All Tools", tableName: "Changes").tag(ToolID?.none)
                Divider()
                ForEach(timeline.toolsInTimeline, id: \.id) { entry in
                    Text(verbatim: entry.name).tag(ToolID?.some(entry.id))
                }
            } label: {
                Label { Text("Tool", tableName: "Changes") } icon: { Image(systemName: Symbol.tools) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help(Text("Filter by tool", tableName: "Changes"))
        }
    }
}

// MARK: - Row

private struct ChangeRow: View {
    let row: ChangeTimelineModel.Row
    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    var body: some View {
        if let change = row.change {
            if let tool = change.toolID.flatMap({ model.snapshot?.tool($0) }) {
                Button {
                    model.show(tool: tool.id)
                } label: {
                    ChangeRowContent(change: change, time: row.detectedAt, isLink: true)
                        .padding(DS.Space.s2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(isHovered ? DS.Palette.panelSecondary : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.small))
                .onHover { isHovered = $0 }
                .help(Text("Show tool details", tableName: "Changes"))
            } else {
                ChangeRowContent(change: change, time: row.detectedAt, reservesChevron: true)
                    .padding(DS.Space.s2)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                Image(systemName: Symbol.good)
                    .font(DS.Font.inlineIcon)
                    .foregroundStyle(DS.Palette.highlight)
                    .frame(width: DS.IconSize.inline)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    Text("Started recording environment changes", tableName: "Changes")
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Palette.textPrimary)
                    Text("\(row.toolCount) tools in the first scan", tableName: "Changes")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                TimeLabel(date: row.detectedAt)
            }
            .padding(DS.Space.s2)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Icon, title, details and origin of one change. Also used by Tool Detail.
struct ChangeRowContent: View {
    let change: EnvironmentChange
    let time: Date
    var isLink = false
    var showsDate = false
    var reservesChevron = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
            Image(systemName: ChangeText.symbol(change.kind))
                .font(DS.Font.inlineIcon)
                .foregroundStyle(ChangeText.tint(change.kind))
                .frame(width: DS.IconSize.inline)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text(ChangeText.title(change))
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(2)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.s3) {
                        ChangeDetail(change: change)
                        OriginLabel(origin: change.origin)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        ChangeDetail(change: change)
                        OriginLabel(origin: change.origin)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TimeLabel(date: time, showsDate: showsDate)
            if isLink || reservesChevron {
                // Unlinked rows keep the space so times line up.
                Image(systemName: "chevron.right")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .opacity(isLink ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ChangeDetail: View {
    let change: EnvironmentChange

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            switch change.kind {
            case .versionChanged:
                VersionChange(from: change.from, to: change.to)
                provider(change.provider)
            case .toolAdded, .installationAdded:
                version(change.to)
                provider(change.provider)
            case .toolRemoved, .installationRemoved:
                version(change.from)
                provider(change.provider)
            case .providerChanged:
                if let previous = change.previousProvider {
                    InstalledViaLabel(provider: previous, font: DS.Font.caption)
                        .fixedSize()
                }
                arrow
                provider(change.provider)
                if change.from != nil || change.to != nil {
                    VersionChange(from: change.from, to: change.to)
                }
            case .activeExecutableChanged:
                if let from = change.from { PathText(path: from, color: DS.Palette.textSecondary) }
                arrow
                if let to = change.to { PathText(path: to) }
                provider(change.provider)
            case .pathEntryAdded:
                PriorityBadge(priority: change.to.flatMap { Int($0) }).fixedSize()
                PathText(path: change.subject ?? "")
            case .pathEntryRemoved:
                PriorityBadge(priority: change.from.flatMap { Int($0) }).fixedSize()
                PathText(path: change.subject ?? "", color: DS.Palette.textSecondary)
            case .pathEntryMoved:
                Text(verbatim: "#\(change.from ?? "?") → #\(change.to ?? "?")")
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize()
                PathText(path: change.subject ?? "")
            case .serviceStarted, .serviceStopped:
                provider(change.provider)
            case .unrecognizedToolsAdded, .unrecognizedToolsRemoved:
                Text(verbatim: change.names.joined(separator: ", ") + ((change.count ?? 0) > change.names.count ? " …" : ""))
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var arrow: some View {
        Image(systemName: Symbol.arrowRight)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Palette.textTertiary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func version(_ value: String?) -> some View {
        if let value {
            Text(value)
                .font(DS.Font.mono)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func provider(_ id: ProviderID?) -> some View {
        if let id {
            InstalledViaLabel(provider: id, font: DS.Font.caption)
                .fixedSize()
        }
    }
}

private struct OriginLabel: View {
    let origin: ChangeOrigin

    var body: some View {
        IconText(
            symbol: ChangeText.originSymbol(origin),
            text: ChangeText.origin(origin),
            tint: origin.kind == .clistate ? DS.Palette.highlight : DS.Palette.textTertiary,
            textColor: DS.Palette.textSecondary,
            font: DS.Font.caption
        )
        .fixedSize()
        .help(ChangeText.originHelp(origin))
    }
}

private struct TimeLabel: View {
    let date: Date
    var showsDate = false

    var body: some View {
        Text(date, format: showsDate ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.hour().minute())
            .font(DS.Font.caption)
            .foregroundStyle(DS.Palette.textTertiary)
            .monospacedDigit()
            .fixedSize()
    }
}
