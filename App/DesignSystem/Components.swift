import AppKit
import CLIStateDomain
import SwiftUI

// MARK: - IconText

/// SF Symbol + text. Every status in the app is shown this way, never by color alone.
struct IconText: View {
    let symbol: String
    let text: String
    var tint: Color = DS.Palette.textSecondary
    var textColor: Color?
    var font: Font = DS.Font.body

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            Image(systemName: symbol)
                .font(DS.Font.inlineIcon)
                .dsForeground(tint)
                .frame(width: DS.IconSize.inline, height: DS.IconSize.inline)
                .accessibilityHidden(true)
            Text(text)
                .font(font)
                .dsForeground(textColor ?? tint)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - StatusLabel

enum StatusKind: String, CaseIterable, Hashable, Sendable {
    case latest, updateAvailable, active, shadowed, notLinked, running, stopped, needsAttention, systemManaged, unknown

    var title: String {
        switch self {
        case .latest: String(localized: "Latest")
        case .updateAvailable: String(localized: "Update Available")
        case .active: String(localized: "Active")
        case .shadowed: String(localized: "Shadowed")
        case .notLinked: String(localized: "Not Linked")
        case .running: String(localized: "Running")
        case .stopped: String(localized: "Stopped")
        case .needsAttention: String(localized: "Needs Attention")
        case .systemManaged: String(localized: "System Managed")
        case .unknown: String(localized: "Unknown")
        }
    }

    var symbol: String {
        switch self {
        case .latest: Symbol.latest
        case .updateAvailable: Symbol.updateAvailable
        case .active: Symbol.active
        case .shadowed: Symbol.shadowed
        case .notLinked: Symbol.notLinked
        case .running: Symbol.running
        case .stopped: Symbol.stopped
        case .needsAttention: Symbol.needsAttention
        case .systemManaged: Symbol.systemManaged
        case .unknown: Symbol.unknown
        }
    }

    var tint: Color {
        switch self {
        case .latest, .running: DS.Palette.success
        case .updateAvailable: DS.Palette.highlight
        case .active: DS.Palette.highlight
        case .needsAttention: DS.Palette.warning
        case .systemManaged: DS.Palette.textSecondary
        case .shadowed, .notLinked, .stopped: DS.Palette.textSecondary
        case .unknown: DS.Palette.textTertiary
        }
    }

    /// Sort rank for table columns: things needing action first.
    var rank: Int {
        switch self {
        case .needsAttention: 0
        case .updateAvailable: 1
        case .running: 2
        case .stopped: 3
        case .active: 4
        case .latest: 5
        case .shadowed: 6
        case .notLinked: 7
        case .systemManaged: 8
        case .unknown: 9
        }
    }
}

struct StatusLabel: View {
    let kind: StatusKind
    var font: Font = DS.Font.body

    var body: some View {
        IconText(symbol: kind.symbol, text: kind.title, tint: kind.tint, font: font)
    }
}

// MARK: - InstalledViaLabel

struct InstalledViaLabel: View {
    let provider: ProviderID
    /// Shown as a suffix when ownership isn't confirmed.
    var confidence: AttributionConfidence? = nil
    var font: Font = DS.Font.body

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            IconText(symbol: Symbol.provider(provider), text: provider.displayName, tint: DS.Palette.textSecondary, textColor: DS.Palette.textPrimary, font: font)
            if confidence == .confirmed {
                Image(systemName: "checkmark.circle.fill")
                    .font(DS.Font.caption)
                    .dsForeground(DS.Palette.success)
                    .help(Text("Installation source confirmed; this is not a security certification."))
                    .accessibilityLabel(Text("Installation source confirmed"))
            } else if let confidence {
                Text(confidence.title)
                    .font(DS.Font.caption)
                    .dsForeground(DS.Palette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Installed via \(provider.displayName)"))
    }
}

// MARK: - KeyValueRow

struct KeyValueRow<Value: View>: View {
    let key: LocalizedStringKey
    let value: Value

    init(_ key: LocalizedStringKey, @ViewBuilder value: () -> Value) {
        self.key = key
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3) {
            Text(key)
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: DS.Layout.keyColumn, alignment: .leading)
            value
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

extension KeyValueRow where Value == Text {
    init(_ key: LocalizedStringKey, text: String) {
        self.key = key
        self.value = Text(text)
    }
}

// MARK: - SectionHeader

struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: String?
    var symbol: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
            if let symbol {
                Image(systemName: symbol)
                    .font(DS.Font.inlineIcon)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: DS.IconSize.inline, height: DS.IconSize.inline)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            Spacer(minLength: DS.Space.s2)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, subtitle: String? = nil, symbol: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.trailing = EmptyView()
    }
}

extension SectionHeader {
    init(_ title: LocalizedStringKey, subtitle: String? = nil, symbol: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.trailing = trailing()
    }
}

// MARK: - PathText

/// Monospaced path, `~`-abbreviated, truncated in the middle, copyable.
struct PathText: View {
    let path: String
    var font: Font = DS.Font.mono
    var color: Color = DS.Palette.textPrimary
    @Environment(\.homeDirectory) private var home

    var body: some View {
        let display = PathRedaction.abbreviatingHome(path, home: home)
        Text(display)
            .font(font)
            .dsForeground(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(display)
            .contextMenu {
                Button("Copy Path", systemImage: Symbol.copy) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
                Button("Reveal in Finder", systemImage: Symbol.reveal) {
                    Finder.reveal(path)
                }
            }
            .accessibilityLabel(Text(display))
    }
}

enum Finder {
    /// Selects the item in Finder, or opens the nearest existing parent directory.
    @MainActor
    static func reveal(_ path: String) {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - EmptyStateView

struct EmptyStateView<Actions: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message { Text(message) }
        } actions: {
            actions
        }
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(_ title: LocalizedStringKey, symbol: String, message: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.message = message
        self.actions = EmptyView()
    }
}

extension EmptyStateView {
    init(_ title: LocalizedStringKey, symbol: String, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.symbol = symbol
        self.message = message
        self.actions = actions()
    }
}

// MARK: - Small pieces

/// `#11` PATH priority tag.
struct PriorityBadge: View {
    let priority: Int?

    var body: some View {
        Text(verbatim: priority.map { "#\($0)" } ?? "—")
            .font(DS.Font.mono)
            .dsForeground(DS.Palette.textTertiary)
            .frame(minWidth: DS.Layout.priorityBadgeWidth)
            .padding(.horizontal, DS.Space.s1)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).strokeBorder(DS.Palette.border, lineWidth: DS.Stroke.hairline))
            .accessibilityLabel(priority.map { Text("PATH priority \($0)") } ?? Text("Not in PATH"))
    }
}

/// `8.5.7 → 8.5.10`
struct VersionChange: View {
    let from: String?
    let to: String?
    var font: Font = DS.Font.mono

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            Text(from ?? "—")
                .dsForeground(DS.Palette.textSecondary)
            if let to {
                Image(systemName: Symbol.arrowRight)
                    .dsForeground(DS.Palette.textTertiary)
                    .accessibilityHidden(true)
                Text(to)
                    .dsForeground(DS.Palette.textPrimary)
            }
        }
        .font(font)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(to.map { Text("From \(from ?? "—") to \($0)") } ?? Text(from ?? "—"))
    }
}

/// Large numeric summary used on Overview.
struct StatTile: View {
    let value: Text
    let title: LocalizedStringKey
    let symbol: String
    var tint: Color = DS.Palette.textSecondary
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: symbol)
                        .font(DS.Font.standaloneIcon)
                        .foregroundStyle(tint)
                        .frame(width: DS.IconSize.standalone, height: DS.IconSize.standalone)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                value
                    .font(DS.Font.display)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .dsCard()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
