import CLIStateDomain
import SwiftUI

struct ToolsView: View {
    let filter: ToolFilter
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\ToolRow.qualifiedName, comparator: .localizedStandard)]
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        // Search and the Scanning settings apply first; the filter bar counts from here.
        let searched = model.tools()
        let rows = self.rows(from: searched)
        GeometryReader { geometry in
            let detailWidth = min(DS.Layout.inspectorIdeal, max(DS.Layout.inspectorMin, geometry.size.width * 0.34))
            let listWidth = max(0, geometry.size.width - (model.isInspectorPresented ? detailWidth + DS.Stroke.hairline : 0))
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: DS.Space.s2) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(DS.Palette.textSecondary)
                        TextField("Name, command, package or provider", text: $model.searchText)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                            .accessibilityLabel(Text("Search tools"))
                        if !model.searchText.isEmpty {
                            Button {
                                model.searchText = ""
                                searchFocused = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Clear search"))
                        }
                    }
                    .dsCard(padding: DS.Space.s3, nested: true)
                    .padding(.horizontal, DS.Space.s4)
                    .padding(.top, DS.Space.s3)
                    ToolFilterBar(filter: filter, tools: searched) { model.route = .tools($0) }
                    if let provider = filter.provider {
                        ProviderHeader(provider: provider)
                    }
                    Group {
                        if rows.isEmpty {
                            emptyState
                        } else {
                            table(rows, width: listWidth)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(width: listWidth)
                .clipped()
                if model.isInspectorPresented {
                    Rectangle().fill(DS.Palette.border).frame(width: DS.Stroke.hairline)
                    detailPanel
                        .frame(width: detailWidth)
                        .frame(maxHeight: .infinity)
                }
            }
            // Inspector visibility must never ask the outer navigation split to collapse.
            .transaction { $0.disablesAnimations = true }
        }
        .dsPageTitle(Text("Tools"), symbol: Symbol.tools)
        .background {
            Button("Search tools") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
        .onChange(of: model.toolSelection) { _, newValue in
            if newValue != nil { model.isInspectorPresented = true }
        }
    }

    private var detailPanel: some View {
        inspectorContent
            .background(DS.Palette.panelPrimary)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if filter.isFiltered {
            EmptyStateView("No matching tools", symbol: Symbol.tools, message: String(localized: "No tools match the selected filters.")) {
                Button("Clear Filters") { model.route = .tools(.all) }
            }
        } else if model.searchText.isEmpty {
            EmptyStateView("No tools", symbol: Symbol.tools, message: String(localized: "Nothing in this list was found in your PATH."))
        } else {
            ContentUnavailableView.search(text: model.searchText)
        }
    }

    private func rows(from tools: [Tool]) -> [ToolRow] {
        // Same-named tools (npm and Bun both installing `@opencode-ai/cli`) get
        // their provider next to the name. Checked across all visible tools so
        // search results stay qualified too.
        let ambiguous = model.visibleTools.ambiguousDisplayNames
        return tools.filter(filter.matches).map { tool in
            ToolRow(tool: tool, providerQualifier: ambiguous.contains(tool.identity.displayName) ? tool.primaryProvider?.displayName : nil)
        }
        .sorted(using: sortOrder)
    }

    /// Narrow tables (inspector open, small window) drop "Installed via" rather than
    /// scrolling sideways; the inspector shows it for the selected tool.
    private func table(_ rows: [ToolRow], width: CGFloat) -> some View {
        let showsProviderColumn = width >= DS.Layout.toolsTableFullWidth
        let showsVersionColumn = width >= DS.Layout.toolsTableVersionWidth
        @Bindable var model = model
        return Table(rows, selection: $model.toolSelection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.qualifiedName, comparator: .localizedStandard) { row in
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: Symbol.category(row.tool.identity.category))
                        .font(DS.Font.inlineIcon)
                        .dsForeground(DS.Palette.textSecondary)
                        .frame(width: DS.IconSize.inline, height: DS.IconSize.inline)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        nameText(row)
                        if !showsVersionColumn { versionCell(row) }
                        if let qualifier = row.providerQualifier {
                            Text(verbatim: qualifier)
                                .font(DS.Font.caption)
                                .dsForeground(DS.Palette.textSecondary)
                                .lineLimit(1)
                        }
                    }

                }
                .frame(minHeight: DS.Layout.tableRowHeight)
                .help(row.qualifiedName)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: [row.name, row.providerQualifier, row.categoryTitle, showsVersionColumn ? nil : row.version, showsVersionColumn ? nil : row.tool.primaryInstallation?.latest?.value.rawValue].compactMap { $0 }.joined(separator: ", ")))
            }
            .width(min: DS.Layout.nameColumnMin)

            if showsVersionColumn {
            TableColumn("Version", value: \.version, comparator: .localizedStandard) { row in
                versionCell(row)
            }
            .width(DS.Layout.versionColumnWidth)
            }

            if showsProviderColumn {
                TableColumn("Installed via", value: \.providerTitle, comparator: .localizedStandard) { row in
                    installedViaCell(row)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(DS.Layout.viaColumnWidth)
            }

            TableColumn("State", value: \.statusRank) { row in
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    StatusLabel(kind: row.status)
                    if row.status == .systemManaged, row.tool.hasUpdate {
                        Text("Other copy has updates")
                            .font(DS.Font.caption)
                            .dsForeground(DS.Palette.textSecondary)
                    }
                }
            }
            .width(DS.Layout.stateColumnWidth)
        }
        .contextMenu(forSelectionType: ToolID.self) { ids in
            if let id = ids.first, let tool = model.snapshot?.tool(id) {
                ToolContextMenu(tool: tool, model: model)
            }
        } primaryAction: { ids in
            if let id = ids.first { model.show(tool: id) }
        }
        .alternatingRowBackgrounds(.disabled)
        .dsScrollBackground()
        .fitsTableColumn(columnsKey: showsProviderColumn ? 4 : (showsVersionColumn ? 3 : 2))
    }

    private func nameText(_ row: ToolRow) -> some View {
        Text(row.name)
            .font(DS.Font.toolName)
            .dsForeground(DS.Palette.textPrimary)
            .lineLimit(1)
    }

    private func installedViaCell(_ row: ToolRow) -> some View {
        HStack(spacing: DS.Space.s1) {
            if let provider = row.provider {
                InstalledViaLabel(provider: provider, confidence: row.tool.primaryInstallation?.ownership.confidence ?? .unknown)
            }
            if row.extraInstallations > 0 {
                Text(verbatim: "+\(row.extraInstallations)")
                    .font(DS.Font.caption)
                    .dsForeground(DS.Palette.textSecondary)
                    .fixedSize()
                    .help(Text("\(row.extraInstallations) more installations"))
                    .accessibilityLabel(Text("\(row.extraInstallations) more installations"))
            }
        }
    }

    private func versionCell(_ row: ToolRow) -> some View {
        let primary = row.tool.primaryInstallation
        return HStack(spacing: DS.Space.s1) {
            Text(row.version)
                .font(DS.Font.mono)
                .dsForeground(DS.Palette.textPrimary)
            if let primary, primary.hasUpdate, let latest = primary.latest?.value.rawValue {
                Image(systemName: Symbol.arrowRight)
                    .font(DS.Font.caption)
                    .dsForeground(DS.Palette.textTertiary)
                    .accessibilityHidden(true)
                Text(latest)
                    .font(DS.Font.mono)
                    .dsForeground(DS.Palette.highlight)
            }
        }
        .accessibilityElement(children: .combine)
        .help([row.version, primary?.latest?.value.rawValue].compactMap { $0 }.joined(separator: " → "))
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let id = model.toolSelection, let tool = model.snapshot?.tool(id) {
            ToolDetailView(tool: tool)
        } else {
            EmptyStateView("No selection", symbol: Symbol.tools, message: String(localized: "Select a tool to see how it's installed and which binary Terminal runs."))
        }
    }
}

private struct ProviderHeader: View {
    let provider: ProviderID
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.providerSnapshot(provider)
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s4) {
            IconText(symbol: Symbol.provider(provider), text: provider.displayName, tint: DS.Palette.textSecondary, textColor: DS.Palette.textPrimary, font: DS.Font.headline)
            if let availability = snapshot?.availability {
                if let version = availability.version {
                    Text(version)
                        .font(DS.Font.mono)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                if let executable = availability.executable {
                    PathText(path: executable, color: DS.Palette.textSecondary)
                }
            }
            Spacer()
            if let downloaded = snapshot?.metadataUpdatedAt {
                Text("Package info updated \(RelativeTime.text(downloaded))")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            } else if let checked = snapshot?.latestCheckedAt {
                Text("Last checked \(RelativeTime.text(checked))")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s2)
        .background(DS.Palette.panelPrimary)
        .overlay(alignment: .bottom) { Divider() }
    }
}
