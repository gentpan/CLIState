import CLIStateDomain
import SwiftUI

struct UpdatesView: View {
    @Environment(AppModel.self) private var model
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        let items = model.updateItems
        let skipped = model.skippedUpdateItems
        Group {
            if items.isEmpty && skipped.isEmpty {
                EmptyStateView("Everything is on the latest version", symbol: StatusKind.latest.symbol, message: String(localized: "Check again to look for new releases."))
            } else {
                List {
                    ForEach(groups(items), id: \.provider) { group in
                        Section {
                            ForEach(group.items) { item in
                                UpdateRow(item: item, isSkipped: false, wide: contentWidth >= DS.Layout.toolsTableFullWidth)
                            }
                        } header: {
                            providerHeader(group.provider, count: group.items.count)
                        }
                    }
                    if !skipped.isEmpty {
                        Section {
                            ForEach(skipped) { item in
                                UpdateRow(item: item, isSkipped: true, wide: contentWidth >= DS.Layout.toolsTableFullWidth)
                            }
                        } header: {
                            Text("Skipped versions")
                                .font(DS.Font.captionEmphasis)
                        }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .dsScrollBackground()
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .disabled(model.isRefreshingMetadata)
        .overlay {
            if model.isRefreshingMetadata || model.isScanning {
                ZStack {
                    DS.Palette.background.opacity(0.75)
                    ProgressView("Refreshing package information and checking updates…")
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .padding(DS.Space.s6)
                        .dsCard()
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                DSWorklistHeader(Text("\(items.count) updates"), symbol: Symbol.updates) {
                    headerMetadata
                } actions: {
                    headerActions(items)
                }
                if let error = model.metadataRefreshError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.s3)
                        .background(DS.Palette.panelPrimary)
                }
            }
            .disabled(model.isRefreshingMetadata)
        }
        .dsPageTitle(Text("Updates"), symbol: Symbol.updates)
    }

    private var headerMetadata: some View {
        HStack(spacing: DS.Space.s2) {
            if let checked = model.snapshot?.latestCheckedAt ?? model.providerSnapshot(.homebrew)?.latestCheckedAt {
                Label(RelativeTime.text(checked), systemImage: "clock")
                    .help(Text("Last checked \(RelativeTime.text(checked))"))
            }
            let major = model.updateItems.filter { $0.installation.updateKind == .major }.count
            if major > 0 {
                Label("\(major) major updates", systemImage: Symbol.needsAttention)
                    .foregroundStyle(DS.Palette.warning)
            }
        }
        .help(Text("Updates don't affect environment status. Automatic updates skip major versions unless you allow them."))
    }

    private func headerActions(_ items: [UpdateItem]) -> some View {
        HStack(spacing: DS.Space.s2) {
            Button { Task { await model.checkForUpdates() } } label: {
                Label("Check for Updates", systemImage: Symbol.updates)
            }
            .modifier(DSGlassButton())
            Button { model.requestUpdateAll() } label: {
                Label("Update All", systemImage: Symbol.update)
            }
            .modifier(DSGlassButton(prominent: true))
            .disabled(items.filter { ToolActionsAvailable.canUpdate($0.installation) }.isEmpty)
        }
        .disabled(model.isPreparingOperation || model.isScanning || model.isOperationRunning || model.isRefreshingMetadata)
    }

    private func providerHeader(_ provider: ProviderID, count: Int) -> some View {
        HStack(spacing: DS.Space.s2) {
            InstalledViaLabel(provider: provider, font: DS.Font.captionEmphasis)
            Text("\(count) updates")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
            Spacer()
            if let checked = model.providerSnapshot(provider)?.latestCheckedAt {
                Text("Checked \(RelativeTime.text(checked))")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }

    private func groups(_ items: [UpdateItem]) -> [(provider: ProviderID, items: [UpdateItem])] {
        let order: [ProviderID] = [.homebrew, .npm, .uv, .native]
        func rank(_ provider: ProviderID) -> Int { order.firstIndex(of: provider) ?? order.count }
        return Dictionary(grouping: items, by: \.provider)
            .map { entry in
                (provider: entry.key, items: entry.value.sorted { $0.tool.identity.displayName.localizedStandardCompare($1.tool.identity.displayName) == .orderedAscending })
            }
            .sorted { lhs, rhs in
                rank(lhs.provider) == rank(rhs.provider) ? lhs.provider < rhs.provider : rank(lhs.provider) < rank(rhs.provider)
            }
    }
}

private struct UpdateRow: View {
    let item: UpdateItem
    let isSkipped: Bool
    let wide: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if wide {
                HStack(alignment: .center, spacing: DS.Space.s4) {
                    identity.frame(minWidth: DS.Layout.nameColumnMin, maxWidth: .infinity, alignment: .leading)
                    versionSummary
                    actions
                }
            } else {
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    HStack(alignment: .top, spacing: DS.Space.s3) { identity; Spacer(minLength: DS.Space.s2); actions }
                    versionSummary
                }
            }
        }
        .padding(.vertical, DS.Space.s2)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            name
            HStack(spacing: DS.Space.s3) {
                Label(purpose, systemImage: purposeSymbol)
                if let usage = item.installation.diskUsage {
                    Text(ByteText.text(usage.bytes, partial: usage.isPartial))
                        .help(usage.measuredAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.Palette.textSecondary)
            .lineLimit(1)
            if !ToolActionsAvailable.canUpdate(item.installation) {
                Text("Can't update from CLI State").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }

    private var name: some View {
        Button { model.show(tool: item.tool.id) } label: {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text(item.tool.identity.displayName).font(DS.Font.toolName)
                    .foregroundStyle(DS.Palette.textPrimary).lineLimit(2)
                if let package = item.installation.ownership.packageName,
                   package != item.tool.identity.name, package != item.tool.identity.displayName {
                    Text(package).font(DS.Font.mono).foregroundStyle(DS.Palette.textSecondary)
                }
                if item.installation.linkState == .shadowed {
                    StatusLabel(kind: .shadowed, font: DS.Font.caption)
                }
                if model.effectivePolicy(for: item.tool) == .automatic {
                    Text(AutoUpdatePolicy.automatic.title).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(identityHelp)
    }

    private var identityHelp: String {
        let location = item.installation.installPrefix ?? item.installation.primaryExecutable?.path
        return [item.tool.identity.localizedSummary, location.map { PathRedaction.abbreviatingHome($0, home: model.homeDirectory) }]
            .compactMap { $0 }.joined(separator: "\n")
    }

    private var versionSummary: some View {
        let current = item.installation.version?.value.rawValue ?? "—"
        let latest = item.latestVersion ?? "—"
        let release = releaseLabel(item.latestVersion, channel: item.installation.latestChannel)
        return VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s2) {
                Text(current)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .accessibilityLabel(Text("Current version: \(current)"))
                    .help(Text("Current version: \(current)"))
                Image(systemName: Symbol.arrowRight)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .accessibilityHidden(true)
                Text(latest)
                    .foregroundStyle(DS.Palette.highlight)
                    .accessibilityLabel(Text("Latest version: \(latest)"))
                    .help(Text("Latest version: \(latest)"))
            }
            .font(DS.Font.mono)
            .lineLimit(1)
            .truncationMode(.middle)
            HStack(spacing: DS.Space.s2) {
                UpdateKindTag(kind: item.installation.updateKind)
                if release != String(localized: "No pre-release tag"), release != String(localized: "Channel unknown") {
                    Text(release).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
        .frame(width: wide ? DS.Layout.versionColumnWidth + DS.Layout.stateColumnMin : nil, alignment: .leading)
    }

    private var purposeSymbol: String {
        switch item.tool.identity.name.lowercased() {
        case "ffmpeg", "imagemagick": "film"
        case "pandoc", "typst", "weasyprint": "doc.richtext"
        default: Symbol.category(item.tool.identity.category)
        }
    }

    private var purpose: String {
        switch item.tool.identity.name.lowercased() {
        case "ffmpeg", "imagemagick": String(localized: "Media processing")
        case "pandoc", "typst", "weasyprint": String(localized: "Documents & publishing")
        default: item.tool.identity.category.title
        }
    }

    private var actions: some View {
        HStack(spacing: DS.Space.s2) {
            if isSkipped {
                Button("Stop Skipping") { model.unskip(item) }.modifier(DSGlassButton())
            } else {
                Button("Update") { model.requestUpdate([item.ref]) }
                    .modifier(DSGlassButton())
                    .disabled(!ToolActionsAvailable.canUpdate(item.installation) || model.isPreparingOperation)
                    .accessibilityLabel(Text("Update \(item.tool.identity.displayName)"))
                Menu {
                    Button("Skip This Version") { model.skip(item) }
                    Button("Show Tool") { model.show(tool: item.tool.id) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .frame(minHeight: DS.ControlHeight.regular)
                .accessibilityLabel(Text("Actions"))
            }
        }.fixedSize()
    }

    /// Plain numeric versions are not proof that a vendor's release is stable.
    private func releaseLabel(_ version: String?, channel: String?) -> String {
        let text = [version, channel].compactMap { $0 }.joined(separator: " ").lowercased()
        if text.range(of: #"(?:^|[.\s_-])beta(?:[.\s_-]|\d|$)"#, options: .regularExpression) != nil { return "Beta" }
        if text.range(of: #"(?:^|[.\s_-])(?:alpha|rc|preview|nightly|dev|canary|next)(?:[.\s_-]|\d|$)"#, options: .regularExpression) != nil { return String(localized: "Pre-release") }
        if channel?.lowercased() == "stable" { return String(localized: "Stable release") }
        if let channel, !channel.isEmpty { return String(localized: "\(channel) channel") }
        if let version, let parsed = ToolVersion(version).semantic, parsed.prerelease.isEmpty {
            return String(localized: "No pre-release tag")
        }
        return String(localized: "Channel unknown")
    }

}

struct UpdateKindTag: View {
    let kind: UpdateKind

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            if kind == .major {
                Image(systemName: Symbol.needsAttention)
                    .accessibilityHidden(true)
            }
            Text(kind.title)
        }
        .font(DS.Font.caption)
        .foregroundStyle(kind.tint)
        .padding(.horizontal, DS.Space.s1)
        .background(kind == .major ? DS.Palette.warning.opacity(DS.Opacity.tint) : DS.Palette.panelSecondary, in: RoundedRectangle(cornerRadius: DS.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).strokeBorder(DS.Palette.border, lineWidth: DS.Stroke.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(kind.title) update"))
    }
}
