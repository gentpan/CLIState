import SwiftUI

/// Sidebar rows share the window canvas; selection and hover use neutral fills.
struct SidebarNavigation<ID: Hashable>: View {
    struct Item: Identifiable {
        var id: ID
        var title: LocalizedStringKey
        var symbol: String
        var badge: Int?
        var accessibilityLabel: Text?
        /// Spoken instead of the bare badge number, e.g. "11 updates".
        var accessibilityValue: Text?
    }

    struct Group: Identifiable {
        var id: String
        var title: LocalizedStringKey?
        var items: [Item]
    }

    /// A row that performs an action instead of selecting, such as Settings.
    struct Action: Identifiable {
        var id: String
        var title: LocalizedStringKey
        var symbol: String
        var accessibilityHint: Text?
        var perform: () -> Void
    }

    let groups: [Group]
    @Binding var selection: ID?
    var footer: [Action] = []

    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    ForEach(groups) { group in
                        if let title = group.title {
                            Text(title)
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Palette.textTertiary)
                                .padding(.leading, DS.Space.s3)
                                .padding(.top, DS.Space.s4)
                                .padding(.bottom, DS.Space.s1)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.items) { item in
                            SidebarRow(
                                title: item.title,
                                symbol: item.symbol,
                                badge: item.badge,
                                isSelected: item.id == selection,
                                accessibilityLabel: item.accessibilityLabel,
                                accessibilityValue: item.accessibilityValue
                            ) {
                                selection = item.id
                            }
                        }
                    }
                    if !footer.isEmpty {
                        Spacer(minLength: DS.Space.s4)
                        ForEach(footer) { action in
                            SidebarRow(title: action.title, symbol: action.symbol, accessibilityHint: action.accessibilityHint, action: action.perform)
                        }
                    }
                }
                .padding(.vertical, DS.Space.s3)
                .padding(.horizontal, DS.Space.s2)
                .frame(minHeight: viewport.size.height, alignment: .top)
            }
            .scrollIndicators(.never)
        }
        .background(DS.Palette.background)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let ids = groups.flatMap { $0.items.map(\.id) }
        guard !ids.isEmpty else { return .ignored }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        let next = min(max(current + offset, 0), ids.count - 1)
        selection = ids[next]
        return .handled
    }
}

private struct SidebarRow: View {
    let title: LocalizedStringKey
    let symbol: String
    var badge: Int?
    var isSelected = false
    var accessibilityLabel: Text?
    var accessibilityValue: Text?
    var accessibilityHint: Text?
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: symbol)
                    .font(DS.Font.inlineIcon)
                    .frame(width: DS.IconSize.standalone)
                Text(title)
                    .font(isSelected ? DS.Font.bodyEmphasis : DS.Font.body)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s2)
                if let badge, badge > 0 {
                    Text(badge, format: .number)
                        .font(DS.Font.caption)
                        .monospacedDigit()
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
            .foregroundStyle(isSelected || isHovered ? DS.Palette.textPrimary : DS.Palette.textSecondary)
            .padding(.horizontal, DS.Space.s3)
            .padding(.vertical, DS.Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: DS.Radius.base))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.base))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : DS.Motion.standard, value: isSelected)
        .animation(reduceMotion ? nil : DS.Motion.standard, value: isHovered)
        .accessibilityLabel(accessibilityLabel ?? Text(title))
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint(accessibilityHint ?? Text(verbatim: ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        if isSelected { return DS.Palette.navigationSelection }
        return isHovered ? DS.Palette.navigationHover : .clear
    }

    private var accessibilityValueText: Text {
        guard let badge, badge > 0 else { return Text(verbatim: "") }
        return accessibilityValue ?? Text(badge, format: .number)
    }
}
