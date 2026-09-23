import SwiftUI

/// Solid token buttons for the black/white/blue theme (both appearances).
/// - `primary`: #1464F6 with white text, hover/pressed `highlight`.
/// - `secondary`: panel fill + border; a `.destructive` role turns the label red.
/// - `destructive`: solid `error` with white text for confirming uninstall and cleanup.
private struct LegacyDSButtonStyle: ButtonStyle {
    enum Kind {
        case primary, secondary, destructive
    }

    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        DSButton(configuration: configuration, kind: kind)
    }

    private struct DSButton: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @State private var isHovered = false

        private var isSmall: Bool { controlSize == .small || controlSize == .mini }
        private var isActive: Bool { isEnabled && (isHovered || configuration.isPressed) }

        var body: some View {
            configuration.label
                .font(DS.Font.body)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(foreground)
                .padding(.horizontal, isSmall ? DS.Space.s2 : DS.Space.s3)
                .frame(minHeight: isSmall ? DS.ControlHeight.small : DS.ControlHeight.regular)
                .background(fill, in: RoundedRectangle(cornerRadius: DS.Radius.base))
                .overlay {
                    if kind == .secondary {
                        RoundedRectangle(cornerRadius: DS.Radius.base)
                            .strokeBorder(DS.Palette.border, lineWidth: DS.Stroke.hairline)
                    }
                }
                .opacity(isEnabled ? 1 : DS.Opacity.disabled)
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.base))
                .onHover { isHovered = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary, .destructive: DS.Palette.onAccent
            case .secondary: configuration.role == .destructive ? DS.Palette.error : DS.Palette.textPrimary
            }
        }

        private var fill: Color {
            switch kind {
            case .primary: isActive ? DS.Palette.highlight : DS.Palette.primary
            case .destructive: isActive ? DS.Palette.error.opacity(DS.Opacity.hover) : DS.Palette.error
            case .secondary: isActive ? DS.Palette.border : DS.Palette.panelSecondary
            }
        }
    }
}

/// The shared action style uses native Liquid Glass on supported macOS versions.
struct DSButtonStyle: PrimitiveButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .secondary

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            switch kind {
            case .primary:
                Button(configuration).buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule).tint(DS.Palette.primary)
            case .secondary:
                Button(configuration).buttonStyle(.glass)
                    .buttonBorderShape(.capsule).tint(nil as Color?)
            case .destructive:
                Button(configuration).buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule).tint(DS.Palette.error)
            }
        } else {
            switch kind {
            case .primary: Button(configuration).buttonStyle(LegacyDSButtonStyle(kind: .primary))
            case .secondary: Button(configuration).buttonStyle(LegacyDSButtonStyle(kind: .secondary))
            case .destructive: Button(configuration).buttonStyle(LegacyDSButtonStyle(kind: .destructive))
            }
        }
    }
}

extension PrimitiveButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsDestructive: DSButtonStyle { DSButtonStyle(kind: .destructive) }
}

/// Native glass for primary controls, with a compact variant for list actions.
struct DSGlassButton: ViewModifier {
    var prominent = false
    var compact = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(compact ? .regular : .large)
            } else {
                content.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(compact ? .regular : .large).tint(nil as Color?)
            }
        } else {
            if prominent { content.buttonStyle(.dsPrimary) }
            else { content.buttonStyle(.dsSecondary) }
        }
    }
}
