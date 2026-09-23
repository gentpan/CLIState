import AppKit
import SwiftUI

/// Design tokens. Views reference these instead of literal colors, sizes or spacing.
enum DS {
    /// 4 pt grid: `s1` = 4 … `s16` = 64.
    enum Space {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s6: CGFloat = 24
        static let s8: CGFloat = 32
        static let s12: CGFloat = 48
        static let s16: CGFloat = 64
    }

    enum TextSize {
        static let programName: CGFloat = 13
        static let programTitle: CGFloat = 18
        static let xs: CGFloat = 12
        static let sm: CGFloat = 14
        static let base: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 4
        static let base: CGFloat = 8
        static let large: CGFloat = 8
    }

    enum IconSize {
        static let inline: CGFloat = 16
        static let standalone: CGFloat = 20
    }

    enum Stroke {
        static let hairline: CGFloat = 1
    }

    /// Fixed layout dimensions, kept on the 4 pt grid.
    enum Layout {
        static let sidebarMin: CGFloat = 200
        static let sidebarIdeal: CGFloat = 224
        static let inspectorMin: CGFloat = 304
        static let inspectorIdeal: CGFloat = 352
        static let inspectorMax: CGFloat = 480
        static let drawerHeight: CGFloat = 240
        /// Segment and filter bars under the toolbar (History), with regular-size controls.
        static let pageHeaderMinHeight: CGFloat = 56
        static let sheetWidth: CGFloat = 576
        static let sheetMaxBodyHeight: CGFloat = 480
        static let settingsWidth: CGFloat = 544
        static let keyColumn: CGFloat = 112
        static let cardMinWidth: CGFloat = 352
        static let windowMinWidth: CGFloat = 960
        static let windowMinHeight: CGFloat = 640
        static let windowDefaultWidth: CGFloat = 1280
        static let windowDefaultHeight: CGFloat = 800
        static let priorityBadgeWidth: CGFloat = 32
        static let statColumnMin: CGFloat = 160
        // Tools table: single-line rows, fixed data columns and a flexible name
        // column fitted by `fitsFirstTableColumn`, so the table always fits. Below `toolsTableFullWidth` the
        // "Installed via" column is dropped instead of scrolling sideways.
        static let nameColumnMin: CGFloat = 180
        static let versionColumnWidth: CGFloat = 160
        static let versionColumnMin: CGFloat = 112
        static let viaColumnWidth: CGFloat = 144
        static let viaColumnMin: CGFloat = 112
        static let stateColumnWidth: CGFloat = 104
        static let stateColumnMin: CGFloat = 96
        /// Single-line table rows; 14 pt text with room to breathe (user feedback).
        static let tableRowHeight: CGFloat = 40
        static let pathColumnMin: CGFloat = 200
        static let toolsTableFullWidth: CGFloat = 680
        static let toolsTableVersionWidth: CGFloat = 480
        static let tabsMaxWidth: CGFloat = 560
        static let chartHeight: CGFloat = 180
        static let pathColumnIdeal: CGFloat = 560
        static let commandColumnMin: CGFloat = 240
    }

    enum Font {
        static let caption = SwiftUI.Font.system(size: TextSize.xs)
        static let captionEmphasis = SwiftUI.Font.system(size: TextSize.xs, weight: .semibold)
        static let body = SwiftUI.Font.system(size: TextSize.sm)
        static let bodyEmphasis = SwiftUI.Font.system(size: TextSize.sm, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: TextSize.base, weight: .semibold)
        static let title = SwiftUI.Font.system(size: TextSize.lg, weight: .semibold)
        static let largeTitle = SwiftUI.Font.system(size: TextSize.xl, weight: .semibold)
        static let display = SwiftUI.Font.system(size: TextSize.xxl, weight: .semibold)
        static let toolName = BundledFont.programName(size: TextSize.programName)
        static let toolTitle = BundledFont.programName(size: TextSize.programTitle)
        static let mono = BundledFont.mono(size: TextSize.xs)
        static let monoBody = BundledFont.mono(size: TextSize.sm)
        static let inlineIcon = SwiftUI.Font.system(size: TextSize.sm)
        static let standaloneIcon = SwiftUI.Font.system(size: TextSize.lg)
    }

    /// A shared canvas for the sidebar and content, with neutral cards above it.
    /// Every token resolves per appearance (Settings › General › Appearance:
    /// System, Light or Dark). Blue is reserved for actions and links;
    /// green/orange/red appear only on small status icons and labels.
    enum Palette {
        /// Unified window and sidebar canvas.
        static let background = Color(light: 0xFFFFFF, dark: 0x1C1C1E)
        /// Cards, inspector, table headers and sheet bodies.
        static let panelPrimary = Color(light: 0xF3F3F4, dark: 0x262628)
        /// Inputs, code blocks and nested surfaces.
        static let panelSecondary = Color(light: 0xEAEAEC, dark: 0x303034)
        /// Sidebar row states stay neutral in both appearances.
        static let navigationSelection = Color(light: 0xEEEEF0, dark: 0x303034)
        static let navigationHover = Color(light: 0xF5F5F6, dark: 0x262628)
        /// Borders and separators.
        static let border = Color(light: 0xE3E3E6, dark: 0x38383C)

        static let textPrimary = Color(light: 0x0A0A0A, dark: 0xFFFFFF)
        static let textSecondary = Color(light: 0x5C5C63, dark: 0xB4B4BA)
        /// Disabled text, captions, PATH index numbers. Not for important text on `panelSecondary`.
        static let textTertiary = Color(light: 0x8E8E93, dark: 0x919197)

        /// Brand blue: button fills (with `onAccent` text) and focus rings.
        static let primary = Color(hex: 0x1464F6)
        /// Blue text, links and icons; pressed/hover state of primary buttons.
        static let highlight = Color(light: 0x0F52CC, dark: 0x3D82F8)
        /// Text and icons on `primary` and `error` fills and on emphasized table selection.
        static let onAccent = Color(hex: 0xFFFFFF)

        static let success = Color(light: 0x15803D, dark: 0x22C55E)
        static let warning = Color(light: 0xB45309, dark: 0xF59E0B)
        static let error = Color(light: 0xDC2626, dark: 0xEF4444)
    }

    enum Opacity {
        /// Subtle status tint behind badges, on `panelSecondary`.
        static let tint = 0.12
        static let hover = 0.85
        static let disabled = 0.4
    }

    /// Buttons were 28/24 and looked squeezed with 14 pt CJK text (user feedback).
    enum ControlHeight {
        static let regular: CGFloat = 32
        static let small: CGFloat = 32
    }

    enum Shadow {
        struct Level: Sendable {
            let opacity: Double
            let radius: CGFloat
            let y: CGFloat
        }

        /// `0 1px 3px rgba(0,0,0,0.08)`
        static let level1 = Level(opacity: 0.08, radius: 3, y: 1)
        /// `0 4px 12px rgba(0,0,0,0.1)`
        static let level2 = Level(opacity: 0.1, radius: 12, y: 4)
    }

    enum Motion {
        static let standard = Animation.easeInOut(duration: 0.2)
        /// Seconds; label color changes and reduced-motion replacements.
        static let short: Double = 0.3
    }

}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Resolves per appearance, so a token follows the window it is drawn in
    /// (including the Settings window, sheets and appearance changes at runtime).
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Modifiers

extension View {
    func dsShadow(_ level: DS.Shadow.Level) -> some View {
        shadow(color: .black.opacity(level.opacity), radius: level.radius, x: 0, y: level.y)
    }

    /// Bordered card (no shadow: cards use a border or a shadow, not both).
    /// `nested` cards sit on a panel and use the secondary panel color.
    func dsCard(padding: CGFloat = DS.Space.s4, nested: Bool = false) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(nested ? DS.Palette.panelSecondary : DS.Palette.panelPrimary, in: RoundedRectangle(cornerRadius: nested ? DS.Radius.base : DS.Radius.large))
            .overlay(RoundedRectangle(cornerRadius: nested ? DS.Radius.base : DS.Radius.large).strokeBorder(DS.Palette.border, lineWidth: DS.Stroke.hairline))
    }

    /// Code block for commands, paths and output.
    func dsWell(padding: CGFloat = DS.Space.s3) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.panelSecondary, in: RoundedRectangle(cornerRadius: DS.Radius.base))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.base).strokeBorder(DS.Palette.border, lineWidth: DS.Stroke.hairline))
    }

    /// Table/list chrome: token background instead of system colors.
    func dsScrollBackground(_ color: Color = DS.Palette.background) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(color)
    }

    /// Token foreground that turns `onAccent` on an emphasized (blue) table selection,
    /// where gray, blue and black text would be illegible.
    func dsForeground(_ color: Color) -> some View {
        modifier(SelectionAwareForeground(color: color))
    }

    /// Animates only when Reduce Motion is off.
    func dsAnimation<V: Equatable>(_ value: V, reduceMotion: Bool) -> some View {
        animation(reduceMotion ? nil : DS.Motion.standard, value: value)
    }
}

private struct SelectionAwareForeground: ViewModifier {
    let color: Color
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        content.foregroundStyle(prominence == .increased ? DS.Palette.onAccent : color)
    }
}

extension EnvironmentValues {
    /// Home directory used to abbreviate paths as `~`. Comes from the snapshot's
    /// shell environment so redacted fixtures abbreviate correctly too.
    @Entry var homeDirectory: String = NSHomeDirectory()
}

// A unified blue–green palette is shared by pie sectors and legend strips.
extension DS.Palette {
    static let installationChart: [Color] = [
        Color(light: 0x2563EB, dark: 0x548BFF), Color(light: 0x38BDF8, dark: 0x60CDFF),
        Color(light: 0x14B8A6, dark: 0x2DD4BF), Color(light: 0x059669, dark: 0x34D399),
        Color(light: 0x0284C7, dark: 0x38BDF8), Color(light: 0x67DCC4, dark: 0x7CE8D2),
        Color(light: 0x1E40AF, dark: 0x6888E8), Color(light: 0x22C55E, dark: 0x4ADE80)
    ]
}
