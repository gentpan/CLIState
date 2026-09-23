import CLIStateDomain
import SwiftUI

extension ToolFilter {
    func matches(_ tool: Tool) -> Bool {
        matches(tool, ignoringCategory: false, ignoringProvider: false)
    }

    /// Facet counts ignore their own dimension, so "Runtimes 6" stays visible
    /// while another category is selected.
    func matches(_ tool: Tool, ignoringCategory: Bool, ignoringProvider: Bool) -> Bool {
        if let recency, UsageRecency.classify(tool, now: .now) != recency { return false }
        if !ignoringCategory, let category, tool.identity.category != category { return false }
        if !ignoringProvider, let provider, !tool.installations.contains(where: { $0.ownership.provider == provider }) { return false }
        switch status {
        case .all: return true
        case .updates: return tool.installations.contains(where: \.hasUpdate)
        case .attention: return tool.statusKind == .needsAttention
        case .removable: return tool.installations.contains(where: ToolActionsAvailable.canUninstall)
        case .systemManaged: return tool.installations.contains { InstallationGroup.classify($0) == .system }
        case .direct: return tool.installations.contains { $0.isDirect == true && !$0.isSystemManaged && $0.ownership.permitsMutation }
        case .officialInstaller: return tool.installations.contains { InstallationGroup.classify($0) == .officialInstaller }
        }
    }
}

extension ToolFilter.Status {
    var title: String {
        switch self {
        case .all: String(localized: "All States")
        case .updates: StatusKind.updateAvailable.title
        case .attention: StatusKind.needsAttention.title
        case .removable: String(localized: "Can uninstall")
        case .systemManaged: String(localized: "Managed by macOS")
        case .direct: String(localized: "Installed on request")
        case .officialInstaller: String(localized: "Official installer")
        }
    }
}

/// Category chips on the left, "Installed via" and state menus on the right.
/// Replaces the category picker in the toolbar and the per-category and
/// per-provider sidebar rows.
struct ToolFilterBar: View {
    let filter: ToolFilter
    /// Tools after search, before this bar's filters.
    let tools: [Tool]
    let onChange: (ToolFilter) -> Void

    var body: some View {
        HStack(spacing: DS.Space.s3) {
            // Chips when they all fit; a category menu otherwise, so no chip is ever cut in half.
            // Drawn as an overlay: switching between the two must not change the
            // column's minimum width, or the split view re-lays out endlessly.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: DS.ControlHeight.small + DS.Space.s2)
                .overlay(alignment: .leading) {
                    ViewThatFits(in: .horizontal) {
                        chips
                        categoryMenu
                    }
                }
                .clipped()

            filterMenu
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s2)
        .frame(minHeight: DS.Layout.pageHeaderMinHeight)
        .background(DS.Palette.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Palette.border).frame(height: DS.Stroke.hairline)
        }
    }

    // MARK: Categories

    private var chips: some View {
        DSTabs(selection: Binding(get: { filter.category }, set: { value in update { $0.category = value } }), options: [nil] + categories.map(Optional.some), title: String(localized: "Category")) { category in
            let title = category?.pluralTitle ?? String(localized: "All")
            return "\(title)  \(count(category: category))"
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var categoryMenu: some View {
        Picker(selection: Binding(get: { filter.category }, set: { value in update { $0.category = value } })) {
            Text(verbatim: "\(String(localized: "All"))  \(count(category: nil))").tag(ToolCategory?.none)
            ForEach(categories, id: \.self) { category in
                Text(verbatim: "\(category.pluralTitle)  \(count(category: category))").tag(ToolCategory?.some(category))
            }
        } label: {
            Text("Category")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .padding(.vertical, DS.Space.s1)
    }

    /// Categories present in the current search, in their natural order. The
    /// selected one stays even when empty so it can be deselected.
    private var categories: [ToolCategory] {
        let present = Set(tools.map(\.identity.category))
        return ToolCategory.allCases.filter { present.contains($0) || $0 == filter.category }
    }

    private func count(category: ToolCategory?) -> Int {
        var facet = filter
        facet.category = category
        return tools.filter { facet.matches($0) }.count
    }

    // MARK: Menu

    /// "Installed via" and state share one menu so the category chips keep the room.
    /// Keep the trigger compact so active filters never squeeze the category controls.
    private var filterMenu: some View {
        let providers = providerCounts
        let active = [filter.provider?.displayName, filter.recency?.title, filter.status == .all ? nil : filter.status.title].compactMap { $0 }
        return Menu {
            Picker(selection: Binding(get: { filter.provider }, set: { value in update { $0.provider = value } })) {
                Text("All Providers").tag(ProviderID?.none)
                ForEach(providers, id: \.provider) { entry in
                    Text(verbatim: "\(entry.provider.displayName)  \(entry.count)").tag(ProviderID?.some(entry.provider))
                }
            } label: {
                Text("Installed via")
            }
            .pickerStyle(.inline)
            Picker(selection: Binding(get: { filter.status }, set: { value in update { $0.status = value } })) {
                ForEach(ToolFilter.Status.allCases, id: \.self) { status in
                    Text(status.title).tag(status)
                }
            } label: {
                Text("State")
            }
            .pickerStyle(.inline)
            if !active.isEmpty {
                Divider()
                Button("Clear Filters") {
                    update {
                        $0.provider = nil
                        $0.recency = nil
                        $0.status = .all
                    }
                }
            }
        } label: {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: active.isEmpty ? Symbol.filter : Symbol.filterActive)
                    .foregroundStyle(active.isEmpty ? DS.Palette.textSecondary : DS.Palette.highlight)
                Text("Filter")
                if !active.isEmpty {
                    Text(active.count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(DS.Palette.highlight)
                }
            }
            .font(DS.Font.body)
        }
        .menuStyle(.borderedButton)
        .modifier(DSGlassButton(compact: true))
        .fixedSize()
        .help(Text("Filter by installer or state"))
        .accessibilityLabel(Text("Filter"))
        .accessibilityValue(Text(verbatim: active.joined(separator: " · ")))
    }

    private var providerCounts: [(provider: ProviderID, count: Int)] {
        var counts: [ProviderID: Int] = [:]
        for tool in tools where filter.matches(tool, ignoringCategory: false, ignoringProvider: true) {
            for provider in Set(tool.installations.map(\.ownership.provider)) {
                counts[provider, default: 0] += 1
            }
        }
        if let selected = filter.provider, counts[selected] == nil { counts[selected] = 0 }
        return counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.displayName < rhs.key.displayName : lhs.value > rhs.value
        }
        .map { (provider: $0.key, count: $0.value) }
    }

    private func update(_ change: (inout ToolFilter) -> Void) {
        var next = filter
        change(&next)
        if next != filter { onChange(next) }
    }
}
