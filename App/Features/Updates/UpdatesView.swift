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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.s6) {
                        ForEach(groups(items), id: \.provider) { group in
                            updateGroup(group.items, provider: group.provider)
                        }
                        if !skipped.isEmpty {
                            skippedGroup(skipped)
                        }
                    }
                    .padding(DS.Space.s4)
                }
                .background(DS.Palette.background)
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
                summaryHeader(items)
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

    private var lastCheckedAt: Date? {
        model.snapshot?.latestCheckedAt ?? model.snapshot?.providers.compactMap(\.latestCheckedAt).max()
    }

    private func summaryHeader(_ items: [UpdateItem]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.s4) {
                summary(items.count).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: DS.Space.s2)
                headerActions(items).fixedSize()
            }
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                summary(items.count)
                headerActions(items)
            }
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s3)
        .frame(minHeight: DS.Layout.pageHeaderMinHeight)
        .background(DS.Palette.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Palette.border).frame(height: DS.Stroke.hairline)
        }
    }

    private func summary(_ count: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3) {
                updateCount(count)
                checkedTime
            }
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                updateCount(count)
                checkedTime
            }
        }
    }

    private func updateCount(_ count: Int) -> some View {
        Text("\(count) updates available")
            .font(DS.Font.headline)
            .foregroundStyle(DS.Palette.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var checkedTime: some View {
        if let checked = lastCheckedAt {
            Text("Last checked \(RelativeTime.text(checked))")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
                .help(checked.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private func headerActions(_ items: [UpdateItem]) -> some View {
        HStack(spacing: DS.Space.s2) {
            Button { Task { await model.checkForUpdates() } } label: {
                Label("Recheck", systemImage: Symbol.refresh)
            }
            .buttonStyle(.dsSecondary)
            Button { model.requestUpdateAll() } label: {
                Label("Update All", systemImage: Symbol.update)
            }
            .buttonStyle(.dsPrimary)
            .disabled(items.filter { ToolActionsAvailable.canUpdate($0.installation) }.isEmpty)
        }
        .disabled(model.isPreparingOperation || model.isScanning || model.isOperationRunning || model.isRefreshingMetadata)
    }

    private func updateGroup(_ items: [UpdateItem], provider: ProviderID) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                IconText(symbol: Symbol.provider(provider), text: provider.displayName,
                         tint: DS.Palette.textSecondary, textColor: DS.Palette.textPrimary, font: DS.Font.bodyEmphasis)
                Text(items.count, format: .number)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                Spacer(minLength: DS.Space.s2)
                if let checked = model.providerSnapshot(provider)?.latestCheckedAt,
                   let latest = lastCheckedAt, latest.timeIntervalSince(checked) >= 5 * 60 {
                    Text("Checked \(RelativeTime.text(checked))")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .padding(.horizontal, DS.Space.s4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            updateRows(items, isSkipped: false)
        }
    }

    private func skippedGroup(_ items: [UpdateItem]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                Text("Skipped versions")
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(items.count, format: .number)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(.horizontal, DS.Space.s4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            updateRows(items, isSkipped: true)
        }
    }

    private func updateRows(_ items: [UpdateItem], isSkipped: Bool) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(DS.Palette.border)
                        .frame(height: DS.Stroke.hairline)
                        .padding(.leading, DS.Space.s4)
                }
                UpdateRow(item: item, isSkipped: isSkipped,
                          wide: contentWidth - DS.Space.s4 * 4 >= DS.Layout.toolsTableFullWidth)
                    .padding(.horizontal, DS.Space.s4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.panelPrimary, in: RoundedRectangle(cornerRadius: DS.Radius.base))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.base).strokeBorder(DS.Palette.border, lineWidth: DS.Stroke.hairline))
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
                Button("Stop Skipping") { model.unskip(item) }.buttonStyle(.dsSecondary)
            } else {
                Button("Update") { model.requestUpdate([item.ref]) }
                    .buttonStyle(.dsSecondary)
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
