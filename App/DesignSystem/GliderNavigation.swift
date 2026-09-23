import SwiftUI

/// Vertical navigation with a glowing "glider" that springs to the selected row
/// (adapted from Uiverse.io radio glider by Smit-Prajapati, recolored to brand
/// blue). Gradients and glow are a deliberate, user-requested exception to the
/// flat design rules; they are confined to this component.
struct GliderNavigation<ID: Hashable>: View {
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

    /// A row in the same style that performs an action instead of selecting,
    /// e.g. opening the Settings window. Never selected, skipped by arrow keys.
    struct Action: Identifiable {
        var id: String
        var title: LocalizedStringKey
        var symbol: String
        var accessibilityHint: Text?
        var perform: () -> Void
    }

    let groups: [Group]
    @Binding var selection: ID?
    /// Pinned below the last group, at the bottom of the column when there's room.
    var footer: [Action] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                                .padding(.leading, DS.Glider.labelInset)
                                .padding(.top, DS.Space.s4)
                                .padding(.bottom, DS.Space.s1)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.items) { item in
                            GliderRow(
                                title: item.title,
                                symbol: item.symbol,
                                badge: item.badge,
                                isSelected: item.id == selection,
                                accessibilityLabel: item.accessibilityLabel,
                                accessibilityValue: item.accessibilityValue
                            ) {
                                selection = item.id
                            }
                            .anchorPreference(key: GliderAnchorKey.self, value: .bounds) { anchor in
                                item.id == selection ? anchor : nil
                            }
                        }
                    }
                    if !footer.isEmpty {
                        Spacer(minLength: DS.Space.s4)
                        ForEach(footer) { action in
                            GliderRow(title: action.title, symbol: action.symbol, accessibilityHint: action.accessibilityHint, action: action.perform)
                        }
                    }
                }
                .padding(.vertical, DS.Space.s3)
                .padding(.leading, DS.Glider.railInset)
                .padding(.trailing, DS.Space.s3)
                .frame(minHeight: viewport.size.height, alignment: .top)
                .overlayPreferenceValue(GliderAnchorKey.self) { anchor in
                    GeometryReader { proxy in
                        ZStack(alignment: .topLeading) {
                            if let anchor {
                                let rect = proxy[anchor]
                                GliderIndicator()
                                    .frame(height: rect.height)
                                    .offset(y: rect.minY)
                                    .animation(gliderAnimation, value: rect.minY)
                            }
                        }
                        .offset(x: DS.Glider.railInset)
                    }
                    .allowsHitTesting(false)
                }
            }
            .scrollIndicators(.never)
        }
        .background(DS.Palette.panelPrimary)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
    }

    /// Overshooting spring, the SwiftUI counterpart of `cubic-bezier(0.37, 1.95, 0.66, 0.56)`.
    private var gliderAnimation: Animation {
        reduceMotion ? .easeInOut(duration: DS.Motion.short) : .spring(response: DS.Glider.springResponse, dampingFraction: DS.Glider.springDamping)
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

private struct GliderRow: View {
    let title: LocalizedStringKey
    let symbol: String
    var badge: Int?
    var isSelected = false
    var accessibilityLabel: Text?
    /// Spoken instead of the bare badge number.
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
                        .foregroundStyle(isSelected ? DS.Palette.highlight : DS.Palette.textTertiary)
                }
            }
            .foregroundStyle(foreground)
            .padding(.leading, DS.Glider.labelInset - DS.Glider.railInset)
            .padding(.vertical, DS.Space.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.short), value: isSelected)
        .animation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.short), value: isHovered)
        .accessibilityLabel(accessibilityLabel ?? Text(title))
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint(accessibilityHint ?? Text(verbatim: ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityValueText: Text {
        guard let badge, badge > 0 else { return Text(verbatim: "") }
        return accessibilityValue ?? Text(badge, format: .number)
    }

    private var foreground: Color {
        if isSelected { return DS.Palette.highlight }
        return isHovered ? DS.Palette.textPrimary : DS.Palette.textSecondary
    }
}

/// The moving part: a vertical light bar, a blurred glow behind it and a soft
/// horizontal wash that fades into the row.
private struct GliderIndicator: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        ZStack(alignment: .leading) {
            LinearGradient(colors: [DS.Palette.primary.opacity(isDark ? DS.Glider.washOpacity : DS.Glider.washOpacityLight), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: DS.Glider.washWidth)

            GeometryReader { proxy in
                Rectangle()
                    .fill(DS.Palette.primary.opacity(isDark ? 1 : DS.Glider.glowOpacityLight))
                    .frame(width: DS.Glider.glowWidth, height: proxy.size.height * DS.Glider.glowHeightRatio)
                    .blur(radius: DS.Glider.glowBlur)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: DS.Glider.glowWidth)

            LinearGradient(colors: [.clear, DS.Palette.highlight, .clear], startPoint: .top, endPoint: .bottom)
                .frame(width: DS.Glider.barWidth)
        }
    }
}

private struct GliderAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
