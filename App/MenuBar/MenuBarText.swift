import AppKit
import CLIStateApplication
import CLIStateDomain
import SwiftUI

// Menu bar extra and Shortcuts strings live in `MenuBar.xcstrings` (table "MenuBar"),
// so they merge independently of `Localizable.xcstrings`.

/// Menu bar extra sizes, on the 4 pt grid.
enum MenuBarLayout {
    static let width: CGFloat = 360
    /// Updates listed before "Show All".
    static let updateLimit = 4
    static let updateRowHeight: CGFloat = 32
    static let logoSize: CGFloat = 24
    static let statusDotSize: CGFloat = 8
    /// Menu bar icon canvas (points); the square sits inside with a small inset.
    static let iconCanvas: CGFloat = 18
    static let iconInset: CGFloat = 1.5
    static let iconCornerRadius: CGFloat = 4
    static let iconStroke: CGFloat = 1.75
    static let badgeDiameter: CGFloat = 6
    /// Transparent ring that separates the badge from the glyph.
    static let badgeGap: CGFloat = 1.5
    /// How often "Scanned 3 minutes ago" refreshes.
    static let relativeTimeInterval: TimeInterval = 30
}

enum MenuBarSymbol {
    static let app = Symbol.terminal
    static let open = "macwindow"
    static let quit = "power"
    static let chevron = "chevron.right"
}

enum MenuBarText {
    /// Header subtitle: what CLIState is doing, or when it last scanned.
    static func status(scanState: AppModel.ScanState, isOperationRunning: Bool, capturedAt: Date?, now: Date) -> String {
        if isOperationRunning { return String(localized: "Running an operation…", table: "MenuBar") }
        switch scanState {
        case .scanning(.fast): return String(localized: "Scanning…", table: "MenuBar")
        case .scanning(.deep): return String(localized: "Checking for updates…", table: "MenuBar")
        case .failed: return String(localized: "Last scan failed", table: "MenuBar")
        case .idle: break
        }
        guard let capturedAt else { return String(localized: "Not scanned yet", table: "MenuBar") }
        if now.timeIntervalSince(capturedAt) < 60 { return String(localized: "Scanned just now", table: "MenuBar") }
        let relative = capturedAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
        return String(localized: "Scanned \(relative)", table: "MenuBar")
    }

    static func severityCount(_ entry: IssueSummary.Entry) -> String {
        switch entry.severity {
        case .critical: String(localized: "\(entry.count) critical", table: "MenuBar")
        case .warning: String(localized: "\(entry.count) warnings", table: "MenuBar")
        case .info: String(localized: "\(entry.count) notices", table: "MenuBar")
        }
    }

    /// `1 critical · 2 warnings`, most severe first.
    static func issueBreakdown(_ summary: IssueSummary) -> String {
        summary.breakdown.map(severityCount).joined(separator: " · ")
    }

    /// One sentence for Shortcuts, e.g. "Found 42 tools, 3 updates available and 2 issues."
    static func scanSummary(_ digest: EnvironmentDigest) -> String {
        let parts = [
            String(localized: "\(digest.toolCount) tools", table: "MenuBar"),
            String(localized: "\(digest.updates.count) updates available", table: "MenuBar"),
            String(localized: "\(digest.issues.total) issues", table: "MenuBar"),
        ]
        let separator = String(localized: "summary.separator", defaultValue: ", ", table: "MenuBar", comment: "Between the counts in the Shortcuts scan summary")
        var sentence = String(localized: "Found \(parts.joined(separator: separator)).", table: "MenuBar")
        if digest.issues.critical > 0 {
            sentence += " " + String(localized: "\(digest.issues.critical) critical issues need attention.", table: "MenuBar")
        }
        return sentence
    }
}

extension HealthSeverity {
    /// Icon tint for a count row; color is never the only signal.
    var menuTint: Color {
        switch self {
        case .critical: DS.Palette.error
        case .warning: DS.Palette.warning
        case .info: DS.Palette.textSecondary
        }
    }
}

@MainActor
enum MenuBarIcon {
    /// Built once: a new image instance on every render would count as a change
    /// to the menu bar extra and update the scene again.
    static let plain = image(badged: false)
    static let badged = image(badged: true)

    /// The app icon as a template glyph (user request): a rounded square with the
    /// terminal prompt `>_` cut out, and a dot cut into the corner when updates are available.
    private static func image(badged: Bool) -> NSImage {
        let size = MenuBarLayout.iconCanvas
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let square = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: MenuBarLayout.iconInset, dy: MenuBarLayout.iconInset)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: square, xRadius: MenuBarLayout.iconCornerRadius, yRadius: MenuBarLayout.iconCornerRadius).fill()

            // `>_`, positioned like the app icon: chevron left of centre, underscore on its baseline.
            let unit = square.width / 16
            let prompt = NSBezierPath()
            prompt.move(to: NSPoint(x: square.minX + 4.2 * unit, y: square.minY + 4.6 * unit))
            prompt.line(to: NSPoint(x: square.minX + 7.6 * unit, y: square.midY))
            prompt.line(to: NSPoint(x: square.minX + 4.2 * unit, y: square.maxY - 4.6 * unit))
            prompt.move(to: NSPoint(x: square.minX + 9.2 * unit, y: square.maxY - 4.6 * unit))
            prompt.line(to: NSPoint(x: square.maxX - 3.4 * unit, y: square.maxY - 4.6 * unit))
            prompt.lineWidth = MenuBarLayout.iconStroke
            prompt.lineCapStyle = .round
            prompt.lineJoinStyle = .round
            NSGraphicsContext.current?.compositingOperation = .clear
            prompt.stroke()

            if badged {
                let diameter = MenuBarLayout.badgeDiameter
                let dot = NSRect(x: size - diameter, y: 0, width: diameter, height: diameter)
                let gap = MenuBarLayout.badgeGap
                NSBezierPath(ovalIn: dot.insetBy(dx: -gap, dy: -gap)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                // Template images use only alpha; the menu bar tints the glyph.
                NSBezierPath(ovalIn: dot).fill()
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        return image
    }
}
