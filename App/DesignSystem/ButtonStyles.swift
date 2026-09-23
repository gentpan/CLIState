import SwiftUI

/// Content actions use native macOS bordered buttons. Glass belongs to the toolbar.
struct DSButtonStyle: PrimitiveButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .secondary

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        switch kind {
        case .primary:
            Button(configuration).buttonStyle(.borderedProminent).tint(DS.Palette.primary)
        case .secondary:
            Button(configuration).buttonStyle(.bordered).tint(nil as Color?)
        case .destructive:
            Button(configuration).buttonStyle(.borderedProminent).tint(DS.Palette.error)
        }
    }
}

extension PrimitiveButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsDestructive: DSButtonStyle { DSButtonStyle(kind: .destructive) }
}

/// Reserve Liquid Glass for native toolbar actions on macOS 26 and newer.
struct DSToolbarGlassButton: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
