import CLIStateDomain
import SwiftUI

/// "Recent changes" in Tool Detail: the last few timeline entries for this tool.
struct RecentChangesSection: View {
    let tool: Tool
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.timeline.recentChanges(for: tool.id)
        Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                        Text("Recent changes", tableName: "Changes")
                            .font(DS.Font.headline)
                            .foregroundStyle(DS.Palette.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: DS.Space.s2)
                        Button {
                            model.timeline.toolFilter = tool.id
                            model.timeline.typeFilter = .all
                            model.timeline.searchText = ""
                            model.route = .history
                        } label: {
                            Text("Show All", tableName: "Changes")
                        }
                        .buttonStyle(.dsSecondary)
                        .font(DS.Font.caption)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.s2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if let change = row.change {
                                ChangeRowContent(change: change, time: row.detectedAt, showsDate: true)
                            }
                            if index < rows.count - 1 { Divider() }
                        }
                    }
                    .dsCard(padding: DS.Space.s3, nested: true)
                }
            }
        }
    }
}

/// "Support" row in an installation card, from endoflife.date release cycles.
struct SupportStatusRow: View {
    let support: RuntimeSupportStatus

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text("Support", tableName: "Changes")
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.textSecondary)

            VStack(alignment: .leading, spacing: 0) {
                Label(EndOfLifeText.status(support), systemImage: EndOfLifeText.symbol(support.phase))
                    .font(DS.Font.caption).foregroundStyle(EndOfLifeText.tint(support.phase))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = EndOfLifeText.detail(support) {
                    Text(detail)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(EndOfLifeText.help(support))
        .accessibilityElement(children: .combine)
    }
}
