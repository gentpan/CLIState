import Charts
import CLIStateDomain
import SwiftUI

struct OverviewCharts: View {
    let tools: [Tool]
    let width: CGFloat
    @Environment(AppModel.self) private var model

    @State private var chart = OverviewChartSection.sources

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            DSTabs(selection: $chart, options: OverviewChartSection.allCases, title: String(localized: "Overview charts")) { $0.title }
                .frame(maxWidth: DS.Layout.tabsMaxWidth)
            switch chart {
            case .sources: InstallationDistributionCard(tools: tools)
            case .versions: VersionTrendCard(tools: tools)
            case .usage: UsageDistributionCard(tools: tools)
            }
            DisclosureGroup {
                accessCard.padding(.top, DS.Space.s3)
            } label: {
                Label("What can I manage?", systemImage: "slider.horizontal.3").font(DS.Font.bodyEmphasis)
            }
        }
    }

    private var accessCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            SectionHeader("What can I manage?", symbol: "slider.horizontal.3")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s3), count: width >= 4 * DS.Layout.statColumnMin ? 4 : 2), spacing: DS.Space.s3) {
                ForEach([ToolFilter.Status.removable, .direct, .officialInstaller, .systemManaged], id: \.self) { status in
                    let filter = ToolFilter(status: status)
                    Button {
                        model.searchText = ""
                        model.route = .tools(filter)
                    } label: {
                        VStack(alignment: .leading, spacing: DS.Space.s1) {
                            Text(status.title).font(DS.Font.body)
                            Text(tools.count(where: filter.matches), format: .number).font(DS.Font.title)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text("Counts are tools and may overlap when a tool has multiple installations. Official installer describes the installation source, not a security certification.")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            Text("macOS copies are maintained through system updates. A Homebrew copy of the same tool is a separate installation with its own update and uninstall actions.")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
        }
        .dsCard()
    }
}

private struct VersionTrendCard: View {
    let tools: [Tool]
    @Environment(AppModel.self) private var model
    @State private var window = 30
    @State private var selection: Date?

    var body: some View {
        let trend = VersionTrend(events: model.timeline.events, visibleIDs: Set(tools.map(\.id)), window: window)
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            SectionHeader("Version change trend", symbol: "chart.xyaxis.line") {
                Button("History") { model.route = .history }.buttonStyle(.dsSecondary)
            }
            DSTabs(selection: $window, options: [7, 30], title: String(localized: "Time range")) {
                String(localized: "\($0) days")
            }
            if !model.timeline.isLoaded {
                ProgressView().frame(height: DS.Layout.chartHeight)
            } else if trend.days.isEmpty {
                Text("No recorded history yet. Trends begin with the first saved scan.")
                    .frame(height: DS.Layout.chartHeight)
            } else {
                Chart(trend.days) { day in
                    LineMark(x: .value("Date", day.date), y: .value("Changes", day.count))
                        .foregroundStyle(DS.Palette.primary)
                    PointMark(x: .value("Date", day.date), y: .value("Changes", day.count))
                        .foregroundStyle(DS.Palette.primary)
                        .accessibilityLabel(Text(day.date, format: .dateTime.month().day()))
                        .accessibilityValue(Text("\(day.count) version changes"))
                }
                .chartYScale(domain: 0...max(1, trend.days.map(\.count).max() ?? 1))
                .chartXScale(domain: (trend.days.first?.date ?? .now)...max((trend.days.first?.date ?? .now).addingTimeInterval(86_400), trend.days.last?.date ?? .now))
                .chartXAxis {
                    AxisMarks(values: stride(from: 0, to: trend.days.count, by: max(1, trend.days.count / 4)).map { trend.days[$0].date }) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
                .chartYAxis {
                    AxisMarks(values: Array(stride(from: 0, through: max(1, trend.days.map(\.count).max() ?? 1), by: max(1, (trend.days.map(\.count).max() ?? 1) / 4))))
                }
                .chartXSelection(value: $selection)
                .frame(height: DS.Layout.chartHeight)
                if let day = trend.days.min(by: { abs($0.date.timeIntervalSince(selection ?? .now)) < abs($1.date.timeIntervalSince(selection ?? .now)) }) {
                    Text("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.count) version changes")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
            }
            Text("Recorded version changes, including external changes and downgrades. Dates are scan detection dates; days before recording began are not counted.")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            ForEach(Array(trend.changes.prefix(3))) { entry in
                Button {
                    if let id = entry.value.toolID { model.show(tool: id) }
                } label: {
                    HStack {
                        Text(entry.value.toolName ?? "—").font(DS.Font.toolName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VersionChange(from: entry.value.from, to: entry.value.to)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .dsCard()
        .onChange(of: window) { _, _ in selection = nil }
    }
}

private struct UsageDistributionCard: View {
    let tools: [Tool]
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    var body: some View {
        let now = Date.now
        let counts = Dictionary(grouping: tools) { UsageRecency.classify($0, now: now) }.mapValues(\.count)
        let selected = selection.flatMap(UsageRecency.init(rawValue:)) ?? .week
        let matches = tools.filter { UsageRecency.classify($0, now: now) == selected }
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            SectionHeader("Usage recency", symbol: "chart.bar.fill")
            VStack(spacing: DS.Space.s3) {
                ForEach(UsageRecency.allCases) { bucket in
                    Button {
                        selection = bucket.rawValue
                    } label: {
                        VStack(alignment: .leading, spacing: DS.Space.s1) {
                            HStack {
                                Text(bucket.title).font(DS.Font.caption)
                                if selected == bucket {
                                    Image(systemName: "checkmark").font(DS.Font.caption)
                                }
                                Spacer(minLength: DS.Space.s2)
                                Text(counts[bucket, default: 0], format: .number)
                                    .font(DS.Font.caption).monospacedDigit()
                            }
                            .foregroundStyle(selected == bucket ? DS.Palette.highlight : DS.Palette.textSecondary)

                        }
                        .frame(minHeight: DS.ControlHeight.regular)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(bucket.title))
                    .accessibilityValue(Text("\(counts[bucket, default: 0]) tools"))
                    .accessibilityAddTraits(selected == bucket ? [.isSelected] : [])
                }
            }
            Text("Estimated from executable access times, not run counts. No record does not mean unused. Select a row to see tools.")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            Picker("Show tools", selection: Binding(get: { selected }, set: { selection = $0.rawValue })) {
                ForEach(UsageRecency.allCases) { Text($0.title).tag($0) }
            }
            if matches.isEmpty {
                Text("No tools in this group.").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            ForEach(Array(matches.sorted { $0.identity.displayName < $1.identity.displayName }.prefix(5))) { tool in
                Button {
                    model.show(tool: tool.id)
                } label: {
                    HStack {
                        Text(tool.identity.displayName).font(DS.Font.toolName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(tool.installations.contains(where: ToolActionsAvailable.canUninstall) ? "Can uninstall" : "Review installation")
                            .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if !matches.isEmpty {
                Button("Show all \(matches.count) tools") {
                    model.searchText = ""
                    model.route = .tools(ToolFilter(recency: selected))
                }
                .buttonStyle(.dsSecondary)
            }
            if selected == .older {
                Text("Review dependencies and your needs before uninstalling. Low activity alone is not a reason to remove a tool.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .dsCard()
    }
}

private struct InstallationDistributionCard: View {
    let tools: [Tool]
    @Environment(AppModel.self) private var model
    @State private var hoveredProvider: ProviderID?
    @FocusState private var focusedProvider: ProviderID?

    private var activeProvider: ProviderID? { hoveredProvider ?? focusedProvider }

    private func sourceColor(_ provider: ProviderID) -> Color {
        let sources: [ProviderID] = [.bun, .cargo, .homebrew, .native, .npm, .standalone, .system, .uv]
        let index = sources.firstIndex(of: provider) ?? provider.rawValue.utf8.reduce(0) { ($0 + Int($1)) % DS.Palette.installationChart.count }
        return DS.Palette.installationChart[index]
    }

    private var entries: [(provider: ProviderID, count: Int)] {
        Dictionary(grouping: tools.flatMap(\.installations), by: { $0.ownership.provider })
            .map { (provider: $0.key, count: $0.value.count) }
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
    }

    var body: some View {
        let data = entries
        let total = data.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            SectionHeader("Installed via", symbol: "chart.pie.fill")
            if total == 0 {
                Text("No installation records yet.").font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.s8) {
                        donut(data).frame(width: DS.Layout.chartHeight + DS.Space.s16, height: DS.Layout.chartHeight + DS.Space.s16)
                        legend(data, total: total).frame(minWidth: 2 * DS.Layout.commandColumnMin + DS.Space.s4)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.s4) {
                        donut(data).frame(height: DS.Layout.chartHeight + DS.Space.s16)
                        legend(data, total: total)
                    }
                }
            }
            Text("Counts installation copies by source. A tool installed through multiple sources is counted in each source. Select a source to view its tools.")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
        }
        .dsCard()
    }

    private func donut(_ data: [(provider: ProviderID, count: Int)]) -> some View {
        let total = data.reduce(0) { $0 + $1.count }
        return Chart(data, id: \.provider) { entry in
            SectorMark(angle: .value("Installations", entry.count),
                       innerRadius: .ratio(0.72),
                       outerRadius: .ratio(activeProvider == entry.provider ? 1 : 0.94),
                       angularInset: DS.Space.s1)
                .cornerRadius(DS.Radius.base)
                .foregroundStyle(sourceColor(entry.provider))
                .opacity(activeProvider == nil || activeProvider == entry.provider ? 1 : DS.Opacity.disabled)
                .accessibilityLabel(Text(entry.provider.displayName))
                .accessibilityValue(Text("\(entry.count) installations"))
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let frame = geometry[plotFrame]
                            let dx = location.x - frame.midX
                            let dy = location.y - frame.midY
                            let radius = min(frame.width, frame.height) / 2
                            let distance = hypot(dx, dy)
                            guard distance <= radius, distance >= radius * 0.72 else {
                                hoveredProvider = nil
                                return
                            }
                            // SectorMark starts at twelve o'clock and proceeds clockwise.
                            let angle = (atan2(dx, -dy) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
                            let value = angle / (2 * .pi) * Double(data.reduce(0) { $0 + $1.count })
                            var upperBound = 0
                            hoveredProvider = data.first { entry in
                                upperBound += entry.count
                                return value < Double(upperBound)
                            }?.provider
                        case .ended: hoveredProvider = nil
                        }
                    }
                    if let anchor = proxy.plotFrame {
                        let frame = geometry[anchor]
                        donutCenter(data, total: total)
                            .frame(width: min(frame.width, frame.height) * 0.62)
                            .position(x: frame.midX, y: frame.midY)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func donutCenter(_ data: [(provider: ProviderID, count: Int)], total: Int) -> some View {
        VStack(spacing: DS.Space.s1) {
            if let selected = data.first(where: { $0.provider == activeProvider }) {
                sourceIcon(selected.provider)
                    .frame(width: DS.IconSize.standalone, height: DS.IconSize.standalone)
                    .accessibilityHidden(true)
                Text(selected.provider.displayName)
                    .font(DS.Font.captionEmphasis)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(selected.count, format: .number).font(DS.Font.largeTitle).monospacedDigit()
                Text(Double(selected.count) / Double(max(total, 1)), format: .percent.precision(.fractionLength(1)))
                    .font(DS.Font.mono).foregroundStyle(DS.Palette.textSecondary)
            } else {
                Text(total, format: .number).font(DS.Font.largeTitle).monospacedDigit()
                Text("Installation copies").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .foregroundStyle(DS.Palette.textPrimary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sourceIcon(_ provider: ProviderID) -> some View {
        if provider == .bun {
            Image("ProviderBun").resizable().scaledToFit()
        } else {
            Image(systemName: provider == .system ? "apple.logo" : Symbol.provider(provider))
                .font(DS.Font.inlineIcon)
                .foregroundStyle(DS.Palette.textSecondary)
        }
    }

    private func sourceDescription(_ provider: ProviderID) -> String {
        switch provider {
        case .bun: String(localized: "Bun: JavaScript runtime and package manager. Counts tools installed through Bun.")
        case .cargo: String(localized: "Cargo: Rust package and build tool. Counts command-line tools installed through Cargo.")
        case .homebrew: String(localized: "Homebrew: package manager for macOS. Counts its managed installations.")
        case .native: String(localized: "Installer: installations attributed to a product's own installer. This label is not a security certification.")
        case .npm: String(localized: "npm: JavaScript package manager. Counts globally installed command-line tools.")
        case .standalone: String(localized: "Standalone: installations not attributed to a supported package manager.")
        case .system: String(localized: "macOS: system-managed copies, maintained with the operating system.")
        case .uv: String(localized: "uv: Python package and project manager. Counts command-line tools installed through uv, not the number of uv copies.")
        default: provider.displayName
        }
    }

    private func legend(_ data: [(provider: ProviderID, count: Int)], total: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s4), count: 2), spacing: DS.Space.s3) {
            ForEach(data, id: \.provider) { entry in
                Button {
                    model.searchText = ""
                    model.route = .tools(ToolFilter(provider: entry.provider))
                } label: {
                    VStack(alignment: .leading, spacing: DS.Space.s2) {
                        RoundedRectangle(cornerRadius: DS.Radius.small)
                            .fill(sourceColor(entry.provider))
                            .frame(height: DS.Space.s2)
                        HStack(spacing: DS.Space.s2) {
                            sourceIcon(entry.provider)
                                .frame(width: DS.IconSize.inline, height: DS.IconSize.inline)
                                .accessibilityHidden(true)
                            Text(entry.provider.displayName).font(DS.Font.body)
                                .lineLimit(1)
                            Spacer(minLength: DS.Space.s1)
                            Text("\(entry.count) installations").font(DS.Font.caption).monospacedDigit()
                                .fixedSize()

                            Text(Double(entry.count) / Double(total), format: .percent.precision(.fractionLength(1)))
                                .font(DS.Font.mono).foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    .padding(DS.Space.s2)
                    .background(activeProvider == entry.provider ? sourceColor(entry.provider).opacity(DS.Opacity.tint) : .clear,
                                in: RoundedRectangle(cornerRadius: DS.Radius.base))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.base)
                            .strokeBorder(activeProvider == entry.provider ? sourceColor(entry.provider) : .clear, lineWidth: DS.Stroke.hairline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(sourceDescription(entry.provider))
                .focused($focusedProvider, equals: entry.provider)
                .onHover { hovering in
                    if hovering { hoveredProvider = entry.provider }
                    else if hoveredProvider == entry.provider { hoveredProvider = nil }
                }
            }
        }
    }
}

extension UsageRecency {
    var title: String {
        switch self {
        case .week: String(localized: "Within 7 days")
        case .month: String(localized: "8–30 days")
        case .quarter: String(localized: "31–90 days")
        case .older: String(localized: "Over 90 days")
        case .unknown: String(localized: "No record")
        }
    }
}

extension InstallationGroup {
    var title: String {
        switch self {
        case .system: String(localized: "Managed by macOS")
        case .officialInstaller: String(localized: "Official installer")
        case .direct: String(localized: "Installed on request")
        case .dependency: String(localized: "Installed as dependency")
        case .unknown: String(localized: "Unclassified")
        }
    }
}

private enum OverviewChartSection: CaseIterable {
    case sources, versions, usage
    var title: String {
        switch self {
        case .sources: String(localized: "Installed via")
        case .versions: String(localized: "Version change trend")
        case .usage: String(localized: "Usage recency")
        }
    }
}
