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
                EmptyStateView("Everything is on the latest version", symbol: StatusKind.latest.symbol, message: String(localized: "Check again to look for new releases.")) {
                    Button("Check for Updates") { Task { await model.checkForUpdates() } }
                        .modifier(DSGlassButton())
                        .disabled(model.isScanning)
                }
            } else {
                List {
                    ForEach(groups(items), id: \.provider) { group in
                        Section {
                            ForEach(group.items) { item in
                                UpdateRow(item: item, isSkipped: false, wide: contentWidth >= UpdateColumns.minimumWidth)
                            }
                        } header: {
                            providerHeader(group.provider, count: group.items.count)
                        }
                    }
                    if !skipped.isEmpty {
                        Section {
                            ForEach(skipped) { item in
                                UpdateRow(item: item, isSkipped: true, wide: contentWidth >= UpdateColumns.minimumWidth)
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
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                header(items)
                if contentWidth >= UpdateColumns.minimumWidth {
                    UpdateColumns.header
                }
                if let error = model.metadataRefreshError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(DS.Font.body).foregroundStyle(DS.Palette.warning)
                        .padding(.horizontal, DS.Space.s4)
                }
            }
            .disabled(model.isRefreshingMetadata)
        }
        .dsPageTitle(Text("Updates"), symbol: Symbol.updates)
    }

    private func header(_ items: [UpdateItem]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.s4) { statusBadges; Spacer(); headerActions(items) }
                VStack(alignment: .leading, spacing: DS.Space.s3) { statusBadges; headerActions(items) }
            }
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s3)
        .background(DS.Palette.panelPrimary)
    }

    private var statusBadges: some View {
        HStack(spacing: DS.Space.s2) {
            Label("\(model.updateItems.count) updates", systemImage: Symbol.update)
                .foregroundStyle(DS.Palette.highlight)
                .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                .background(DS.Palette.primary.opacity(DS.Opacity.tint), in: RoundedRectangle(cornerRadius: DS.Radius.small))
            if let checked = model.snapshot?.latestCheckedAt ?? model.providerSnapshot(.homebrew)?.latestCheckedAt {
                Label(RelativeTime.text(checked), systemImage: "clock")
                    .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                    .background(DS.Palette.panelSecondary, in: RoundedRectangle(cornerRadius: DS.Radius.small))
                    .help(Text("Last checked \(RelativeTime.text(checked))"))
            }
            let major = model.updateItems.filter { $0.installation.updateKind == .major }.count
            if major > 0 {
                Label("\(major) major updates", systemImage: Symbol.needsAttention)
                    .foregroundStyle(DS.Palette.warning)
                    .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                    .background(DS.Palette.warning.opacity(DS.Opacity.tint), in: RoundedRectangle(cornerRadius: DS.Radius.small))
            }
            Image(systemName: "info.circle")
                .help(Text("Updates don't affect environment status. Automatic updates skip major versions unless you allow them."))
        }
        .font(DS.Font.caption)
        .foregroundStyle(DS.Palette.textSecondary)
        .fixedSize()
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
        .fixedSize()
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
                HStack(alignment: .top, spacing: DS.Space.s4) {
                    identity.frame(minWidth: DS.Layout.nameColumnMin, maxWidth: .infinity, alignment: .leading)
                    version("Current version", value: item.installation.version?.value.rawValue, latest: false)
                    version("Latest version", value: item.latestVersion, latest: true)
                    size
                    category
                    actions.frame(width: UpdateColumns.actions, alignment: .trailing)
                }
            } else {
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    HStack(alignment: .top) { identity; Spacer(); actions }
                    HStack(alignment: .top, spacing: DS.Space.s4) {
                        version("Current version", value: item.installation.version?.value.rawValue, latest: false)
                        version("Latest version", value: item.latestVersion, latest: true)
                        size
                        category
                    }
                }
            }
        }
        .padding(.vertical, DS.Space.s3)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            name
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

    private func version(_ title: LocalizedStringKey, value: String?, latest: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            if !wide { Text(title).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1) {
                if latest { UpdateKindTag(kind: item.installation.updateKind).fixedSize() }
                Text(value ?? "—").font(DS.Font.mono)
                    .foregroundStyle(latest ? DS.Palette.highlight : DS.Palette.textPrimary)
                    .lineLimit(2).help(value ?? "—")
            }
            let release = releaseLabel(value, channel: latest ? item.installation.latestChannel : nil)
            if release != String(localized: "No pre-release tag"), release != String(localized: "Channel unknown") {
                Text(release).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
        }.frame(width: latest ? UpdateColumns.latest : DS.Layout.keyColumn, alignment: .leading)
    }

    private var size: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            if !wide { Text("Installed size").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
            if let usage = item.installation.diskUsage {
                Text(ByteText.text(usage.bytes, partial: usage.isPartial)).font(DS.Font.mono)
                    .help(usage.measuredAt.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text("Not measured").font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
            }
        }.frame(width: UpdateColumns.size, alignment: .leading)
    }

    private var category: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            if !wide { Text("Purpose").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
            HStack(spacing: DS.Space.s1) {
                Image(systemName: purposeSymbol)
                    .font(DS.Font.inlineIcon)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: DS.IconSize.inline)
                    .accessibilityHidden(true)
                Text(purpose).font(DS.Font.body)
            }
            .accessibilityElement(children: .combine)
        }.frame(width: UpdateColumns.purpose, alignment: .leading)
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
                Button("Skip This Version") { model.skip(item) }.modifier(DSGlassButton())
                Button("Update") { model.requestUpdate([item.ref]) }
                    .modifier(DSGlassButton())
                    .disabled(!ToolActionsAvailable.canUpdate(item.installation) || model.isPreparingOperation)
                    .accessibilityLabel(Text("Update \(item.tool.identity.displayName)"))
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

private enum UpdateColumns {
    static let size = DS.Layout.stateColumnMin
    static let purpose = DS.Layout.keyColumn
    static let latest = DS.Layout.versionColumnWidth
    static let actions = DS.Layout.versionColumnWidth + DS.Space.s8
    static let minimumWidth = DS.Layout.nameColumnMin + DS.Layout.keyColumn + latest + size + purpose + actions + 7 * DS.Space.s4

    static var header: some View {
        HStack(spacing: DS.Space.s4) {
            Text("Program").frame(minWidth: DS.Layout.nameColumnMin, maxWidth: .infinity, alignment: .leading)
            Text("Current version").frame(width: DS.Layout.keyColumn, alignment: .leading)
            Text("Latest version").frame(width: latest, alignment: .leading)
            Text("Installed size").frame(width: size, alignment: .leading)
            Text("Purpose").frame(width: purpose, alignment: .leading)
            Text("Actions").frame(width: actions, alignment: .trailing)
        }
        .font(DS.Font.captionEmphasis)
        .foregroundStyle(DS.Palette.textSecondary)
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s2)
        .background(DS.Palette.panelPrimary)
        .overlay(alignment: .bottom) { Divider() }
    }
}
