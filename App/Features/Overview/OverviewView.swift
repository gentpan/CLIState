import CLIStateDomain
import SwiftUI

struct OverviewView: View {
    /// `false` renders the page without its scroll view (debug image export).
    var scrolls = true
    @Environment(AppModel.self) private var model
    @State private var contentWidth: CGFloat = .infinity
    @State private var previewRowHeight: CGFloat = DS.Space.s12
    private let previewLimit = 3

    private var previewCardHeight: CGFloat {
        DS.ControlHeight.regular + CGFloat(previewLimit) * previewRowHeight
            + CGFloat(2 * previewLimit - 1) * DS.Space.s3
            + CGFloat(previewLimit - 1) * DS.Stroke.hairline
    }

    var body: some View {
        if let snapshot = model.snapshot {
            if scrolls {
                ScrollView {
                    content(snapshot)
                }
                .dsPageTitle(Text("Overview"), symbol: Symbol.overview)
            } else {
                content(snapshot)
            }
        }
    }

    /// The dashboard without its scroll view, so it can also be rendered to an image.
    func content(_ snapshot: EnvironmentSnapshot) -> some View {
        let usage = OverviewUsage(tools: model.visibleTools)
        return VStack(alignment: .leading, spacing: DS.Space.s6) {
            EnvironmentCheckCard(snapshot: snapshot)
            stats(usage)
            SectionHeader("Needs your attention", symbol: "checklist")
            if contentWidth >= 2 * DS.Layout.cardMinWidth + DS.Space.s4 {
                HStack(alignment: .top, spacing: DS.Space.s4) {
                    issuesCard
                    updatesCard
                }
            } else {
                issuesCard
                updatesCard
            }
            OverviewCharts(tools: model.visibleTools, width: contentWidth)
            DisclosureGroup {
                VStack(spacing: DS.Space.s4) {
                    DiskUsageCard(usage: usage, limit: previewLimit)
                    RecentUseCard(usage: usage, limit: previewLimit)
                    CategoryCard(tools: model.visibleTools)
                    if !snapshot.services.isEmpty { servicesCard(snapshot.services) }
                }
                .padding(.top, DS.Space.s3)
            } label: {
                Label("Storage, categories and services", systemImage: "slider.horizontal.3")
                    .font(DS.Font.bodyEmphasis)
            }

        }
        .onPreferenceChange(OverviewPreviewRowHeight.self) { previewRowHeight = max(DS.Space.s12, $0) }
        .task(id: snapshot.id) {
            await model.timeline.reload(using: model.actions, snapshotID: snapshot.id)
        }
        .padding(DS.Space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * DS.Space.s6 } action: { contentWidth = $0 }
    }

    private func stats(_ usage: OverviewUsage) -> some View {
        let columns = contentWidth >= 4 * DS.Layout.statColumnMin + 3 * DS.Space.s4 ? 4 : 2
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s4), count: columns), spacing: DS.Space.s4) {
            metric("Installed tools", value: String(model.visibleTools.count), symbol: Symbol.tools, route: .tools(.all))
            metric("Updates", value: String(model.updateItems.count), symbol: Symbol.updates, route: .updates)
            metric("Issues", value: String(model.issues.count), symbol: Symbol.issues, route: .issues)
            metricContents("Disk space", value: usage.measuredCount == 0 ? "—" : ByteText.text(usage.totalBytes), symbol: OverviewSymbol.disk)
        }
    }

    private func metric(_ title: LocalizedStringKey, value: String, symbol: String, route: AppRoute) -> some View {
        Button { model.route = route } label: {
            metricContents(title, value: value, symbol: symbol, navigates: true)
        }
        .buttonStyle(.plain)
    }

    private func metricContents(_ title: LocalizedStringKey, value: String, symbol: String, navigates: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s2) {
                Label(title, systemImage: symbol)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                Spacer(minLength: DS.Space.s1)
                if navigates {
                    Image(systemName: "chevron.right")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            Text(value)
                .font(DS.Font.title)
                .monospacedDigit()
                .foregroundStyle(DS.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: DS.Space.s16, alignment: .leading)
        .dsCard()
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.base))
        .accessibilityElement(children: .combine)
    }

    private var updatesCard: some View {
        let items = model.updateItems
        return VStack(alignment: .leading, spacing: DS.Space.s3) {
            SectionHeader("Updates", symbol: Symbol.updates) {
                if !items.isEmpty {
                    Button("Show All") { model.route = .updates }
                        .buttonStyle(.dsSecondary)
                }
            }
            .frame(minHeight: DS.ControlHeight.regular)
            if items.isEmpty {
                IconText(symbol: StatusKind.latest.symbol, text: String(localized: "Everything is on the latest version."), tint: DS.Palette.success, textColor: DS.Palette.textSecondary)
            } else {
                ForEach(items.prefix(previewLimit)) { item in
                    HStack(spacing: DS.Space.s3) {
                        Button {
                            model.show(tool: item.tool.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.tool.identity.displayName)
                                    .font(DS.Font.toolName)
                                    .lineLimit(2)
                                    .foregroundStyle(DS.Palette.textPrimary)
                                VersionChange(from: item.installation.version?.value.rawValue, to: item.latestVersion)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        InstalledViaLabel(provider: item.provider, font: DS.Font.caption)
                        Button("Update") { model.requestUpdate([item.ref]) }
                            .modifier(DSGlassButton(compact: true))
                            .disabled(!ToolActionsAvailable.canUpdate(item.installation) || model.isPreparingOperation)
                            .accessibilityLabel(Text("Update \(item.tool.identity.displayName)"))
                    }
                    .modifier(OverviewPreviewRow(height: previewRowHeight))
                    if item.id != items.prefix(previewLimit).last?.id { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: previewCardHeight, alignment: .topLeading)
        .dsCard()
    }

    private var issuesCard: some View {
        let issues = model.issues
        return VStack(alignment: .leading, spacing: DS.Space.s3) {
            SectionHeader("Issues", symbol: Symbol.issues) {
                if !issues.isEmpty {
                    Button("Show All") { model.route = .issues }
                        .buttonStyle(.dsSecondary)
                }
            }
            .frame(minHeight: DS.ControlHeight.regular)
            if issues.isEmpty {
                IconText(symbol: Symbol.good, text: String(localized: "No issues found."), tint: DS.Palette.success, textColor: DS.Palette.textSecondary)
            } else {
                ForEach(issues.prefix(previewLimit)) { issue in
                    let text = issue.text(in: model.snapshot)
                    Button {
                        model.route = .issues
                    } label: {
                        HStack(alignment: .center, spacing: DS.Space.s2) {
                            Image(systemName: issue.severity.symbol)
                                .font(DS.Font.inlineIcon)
                                .foregroundStyle(issue.severity.tint)
                                .frame(width: DS.IconSize.inline, height: DS.IconSize.inline)
                                // The severity is spoken once, from the trailing text.
                                .accessibilityHidden(true)
                            Text(text.title)
                                .font(DS.Font.body)
                                .lineLimit(2)
                                .foregroundStyle(DS.Palette.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(issue.severity.title)
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(OverviewPreviewRow(height: previewRowHeight))
                    if issue.id != issues.prefix(previewLimit).last?.id { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: previewCardHeight, alignment: .topLeading)
        .dsCard()
    }

    private func servicesCard(_ services: [ToolService]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            SectionHeader("Services", symbol: Symbol.service)
            ForEach(services) { service in
                ServiceRow(service: service)
                if service.id != services.last?.id { Divider() }
            }
        }
        .dsCard()
    }
}

struct ScannedAgoText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text("Scanned \(RelativeTime.text(date, now: context.date))")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textTertiary)
        }
    }
}

enum RelativeTime {
    /// "3 minutes ago"; "just now" under a minute.
    static func text(_ date: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "just now") }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

struct ServiceRow: View {
    let service: ToolService
    @Environment(AppModel.self) private var model

    var body: some View {
        let tool = service.toolID.flatMap { model.snapshot?.tool($0) }
        let capabilities = service.installationID.flatMap { tool?.installation($0) }?.capabilities ?? .none
        let name = tool?.identity.displayName ?? service.name
        HStack(spacing: DS.Space.s3) {
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(service.name)
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IconText(symbol: service.status.symbol, text: service.status.title, tint: service.status.tint)
            HStack(spacing: DS.Space.s1) {
                if capabilities.canStart, service.status != .running {
                    serviceButton(.start, name: name)
                }
                if capabilities.canStop, service.status == .running || service.status == .error {
                    serviceButton(.stop, name: name)
                }
                if capabilities.canRestart {
                    serviceButton(.restart, name: name)
                }
            }
        }
    }

    private func serviceButton(_ action: ServiceAction, name: String) -> some View {
        Button {
            model.requestService(action, service: service)
        } label: {
            Label(action.title, systemImage: action.symbol)
                .labelStyle(.iconOnly)
        }
        .help(action.title(for: name))
        .accessibilityLabel(action.title(for: name))
        .disabled(model.isPreparingOperation)
    }
}

// Measure natural row content before applying the shared height so both cards
// align their dividers without clipping longer names or enlarged text.
private struct OverviewPreviewRow: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: OverviewPreviewRowHeight.self, value: geometry.size.height)
                }
            }
            .frame(minHeight: height)
    }
}

private struct OverviewPreviewRowHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
