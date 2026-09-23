import CLIStateDomain
import SwiftUI

/// Per-tool size and last use for the Overview dashboard, summed over installations.
struct OverviewUsage {
    struct Entry: Identifiable {
        let tool: Tool
        let bytes: Int64?
        /// Some installation's measurement stopped at the file limit.
        let isPartial: Bool
        let lastUsedAt: Date?

        var id: ToolID { tool.id }
    }

    /// Unused for longer than this counts as idle.
    static let idleInterval: TimeInterval = 90 * 24 * 60 * 60

    let entries: [Entry]
    let totalBytes: Int64
    let measuredCount: Int
    let bySize: [Entry]
    let recent: [Entry]
    let idle: [Entry]

    init(tools: [Tool], now: Date = .now) {
        entries = tools.map { tool in
            let measured = tool.installations.compactMap(\.diskUsage)
            return Entry(
                tool: tool,
                bytes: measured.isEmpty ? nil : measured.map(\.bytes).reduce(0, +),
                isPartial: measured.contains(where: \.isPartial),
                lastUsedAt: tool.installations.compactMap(\.lastUsedAt).max()
            )
        }
        let measured = entries.filter { $0.bytes != nil }
        // Two tools can point at the same files (e.g. `grok` and `agent` sharing one
        // binary); the total counts each location once.
        var seen = Set<String>()
        totalBytes = tools.flatMap(\.installations).reduce(into: Int64(0)) { total, installation in
            guard let usage = installation.diskUsage else { return }
            let location = installation.installPrefix ?? installation.primaryExecutable.map { $0.resolvedPath ?? $0.path } ?? installation.id.rawValue
            if seen.insert(location).inserted { total += usage.bytes }
        }
        measuredCount = measured.count
        bySize = measured.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        recent = entries.filter { $0.lastUsedAt != nil }.sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
        idle = entries
            .filter { entry in entry.lastUsedAt.map { now.timeIntervalSince($0) > Self.idleInterval } ?? false }
            .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }
}

enum ByteText {
    /// `1.2 GB`; `≥ 1.2 GB` when the measurement is a lower bound.
    static func text(_ bytes: Int64, partial: Bool = false) -> String {
        let size = bytes.formatted(.byteCount(style: .file))
        return partial ? String(localized: "≥ \(size)") : size
    }
}

// MARK: - Cards

/// Largest tools with proportional bars.
struct DiskUsageCard: View {
    let usage: OverviewUsage
    let limit: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            SectionHeader("Largest tools", symbol: OverviewSymbol.disk)
            if usage.bySize.isEmpty {
                Text("Sizes are measured when CLI State checks for updates.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textSecondary)
            } else {
                let top = Array(usage.bySize.prefix(limit))
                let largest = max(top.first?.bytes ?? 1, 1)
                VStack(alignment: .leading, spacing: DS.Space.s3) {
                    ForEach(top) { entry in
                        Button {
                            model.show(tool: entry.tool.id)
                        } label: {
                            VStack(alignment: .leading, spacing: DS.Space.s1) {
                                HStack(spacing: DS.Space.s2) {
                                    ToolNameLabel(tool: entry.tool)
                                    Spacer(minLength: DS.Space.s2)
                                    Text(ByteText.text(entry.bytes ?? 0, partial: entry.isPartial))
                                        .font(DS.Font.body)
                                        .monospacedDigit()
                                        .foregroundStyle(DS.Palette.textSecondary)
                                }
                                DSSegmentedBar(fraction: Double(entry.bytes ?? 0) / Double(largest))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("\(ByteText.text(usage.totalBytes)) across \(usage.measuredCount) tools")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .dsCard()
    }
}

/// Most recently run tools, then large tools nobody has run for months.
struct RecentUseCard: View {
    let usage: OverviewUsage
    let limit: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            SectionHeader("Recently used", symbol: OverviewSymbol.recent)
            if usage.recent.isEmpty {
                Text("No access recorded yet. Usage estimates come from executable access times; macOS system tools do not provide this information.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(spacing: 0) {
                        ForEach(Array(usage.recent.prefix(limit))) { entry in
                            row(entry.tool) {
                                Text(RelativeTime.text(entry.lastUsedAt ?? .distantPast, now: context.date))
                                    .font(DS.Font.body)
                                    .foregroundStyle(DS.Palette.textSecondary)
                            }
                        }
                    }
                }
            }
            if !usage.idle.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("No recent access for 90 days")
                            .font(DS.Font.captionEmphasis)
                            .foregroundStyle(DS.Palette.textSecondary)
                        Spacer()
                        let idleBytes = usage.idle.compactMap(\.bytes).reduce(0, +)
                        if idleBytes > 0 {
                            Text(ByteText.text(idleBytes))
                                .font(DS.Font.caption)
                                .monospacedDigit()
                                .foregroundStyle(DS.Palette.textTertiary)
                        }
                    }
                    .padding(.bottom, DS.Space.s1)
                    ForEach(Array(usage.idle.prefix(3))) { entry in
                        row(entry.tool) {
                            if let bytes = entry.bytes {
                                Text(ByteText.text(bytes, partial: entry.isPartial))
                                    .font(DS.Font.body)
                                    .monospacedDigit()
                                    .foregroundStyle(DS.Palette.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        .dsCard()
    }

    private func row<Trailing: View>(_ tool: Tool, @ViewBuilder trailing: () -> Trailing) -> some View {
        Button {
            model.show(tool: tool.id)
        } label: {
            HStack(spacing: DS.Space.s2) {
                ToolNameLabel(tool: tool)
                Spacer(minLength: DS.Space.s2)
                trailing()
            }
            .frame(minHeight: DS.ControlHeight.regular)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Tool counts per category; each row opens the Tools page filtered to it.
struct CategoryCard: View {
    let tools: [Tool]
    @Environment(AppModel.self) private var model

    var body: some View {
        let counts = ToolCategory.allCases.compactMap { category -> (ToolCategory, Int)? in
            let count = tools.count { $0.identity.category == category }
            return count > 0 ? (category, count) : nil
        }
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            SectionHeader("Categories", symbol: OverviewSymbol.categories)
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                ForEach(counts, id: \.0) { category, count in
                    Button {
                        model.route = .tools(ToolFilter(category: category))
                    } label: {
                        VStack(alignment: .leading, spacing: DS.Space.s1) {
                            HStack(spacing: DS.Space.s2) {
                                IconText(symbol: Symbol.category(category), text: category.pluralTitle, textColor: DS.Palette.textPrimary)
                                Spacer(minLength: DS.Space.s2)
                                Text(count, format: .number)
                                    .font(DS.Font.body)
                                    .monospacedDigit()
                                    .foregroundStyle(DS.Palette.textSecondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(Text("\(count) tools"))
                }
            }
        }
        .dsCard()
    }
}

/// Tool name with its installer icon, e.g. for dashboard rows.
struct ToolNameLabel: View {
    let tool: Tool

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: Symbol.provider(tool.primaryProvider ?? .standalone))
                .font(DS.Font.inlineIcon)
                .foregroundStyle(DS.Palette.textTertiary)
                .frame(width: DS.IconSize.inline, height: DS.IconSize.inline)
                .help(Text("Installed via \((tool.primaryProvider ?? .standalone).displayName)"))
                .accessibilityHidden(true)
            Text(tool.identity.displayName)
                .font(DS.Font.toolName)
                .foregroundStyle(DS.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

enum OverviewSymbol {
    static let disk = "internaldrive"
    static let recent = "clock"
    static let categories = "square.grid.2x2"
    static let providers = "shippingbox"
}
