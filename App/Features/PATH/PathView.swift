import CLIStateDomain
import SwiftUI

struct PathView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection: PATHEntry.ID?

    var body: some View {
        let entries = model.snapshot?.pathEntries ?? []
        VStack(spacing: 0) {
            lookup
                .padding(DS.Space.s4)
            HStack {
                Text("Review missing and duplicate entries before editing shell configuration.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Button("Environment check") { model.route = .overview }
            }
            .padding(.horizontal, DS.Space.s4)
            .padding(.bottom, DS.Space.s3)
            Divider()
            Table(entries, selection: $selection) {
                TableColumn("Priority") { entry in
                    PriorityBadge(priority: entry.priority)
                }
                .width(DS.Layout.statColumnMin / 2)

                TableColumn("Directory") { entry in
                    PathText(path: entry.rawValue, font: DS.Font.monoBody, color: entry.status == .ok ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                        .frame(minHeight: DS.Layout.tableRowHeight)
                }
                .width(min: DS.Layout.pathColumnMin, ideal: DS.Layout.pathColumnIdeal)

                TableColumn("Source") { entry in
                    Text(entry.source.title)
                        .font(DS.Font.body)
                        .dsForeground(DS.Palette.textSecondary)
                }
                .width(min: DS.Layout.keyColumn, ideal: DS.Layout.keyColumn)

                TableColumn("Commands") { entry in
                    if entry.status == .ok {
                        Text(entry.executableCount, format: .number)
                            .font(DS.Font.body)
                            .monospacedDigit()
                            .dsForeground(DS.Palette.textPrimary)
                    } else {
                        Text(verbatim: "—")
                            .dsForeground(DS.Palette.textTertiary)
                    }
                }
                .width(min: DS.Layout.priorityBadgeWidth * 2, ideal: DS.Layout.priorityBadgeWidth * 2)

                TableColumn("Status") { entry in
                    HStack(spacing: DS.Space.s2) {
                        IconText(symbol: entry.status.symbol, text: statusText(entry), tint: entry.status.tint)
                        if entry.isWritable {
                            Image(systemName: "pencil")
                                .font(DS.Font.caption)
                                .dsForeground(DS.Palette.textTertiary)
                                .help(Text("Writable: your account can add programs to this folder, and Terminal will find them."))
                                .accessibilityLabel(Text("Writable"))
                        }
                    }
                }
                .width(min: DS.Layout.statColumnMin, ideal: DS.Layout.statColumnMin)
            }
            .alternatingRowBackgrounds(.disabled)
            .fitsTableColumn(1, columnsKey: 5)
            .dsScrollBackground()
            .contextMenu(forSelectionType: PATHEntry.ID.self) { ids in
                if let id = ids.first, let entry = entries.first(where: { $0.id == id }) {
                    Button("Copy Path", systemImage: Symbol.copy) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.normalizedPath, forType: .string)
                    }
                    Button("Reveal in Finder", systemImage: Symbol.reveal) {
                        Finder.reveal(entry.normalizedPath)
                    }
                    .disabled(entry.status != .ok)
                }
            }
        }
        .dsPageTitle(Text("PATH"), symbol: Symbol.path)
    }

    private func subtitle(_ entries: [PATHEntry]) -> Text {
        let problems = entries.filter { $0.status != .ok }.count
        return Text("\(entries.count) entries, \(problems) not searched")
    }

    private func statusText(_ entry: PATHEntry) -> String {
        if entry.status == .duplicate, let first = entry.duplicateOf {
            return String(localized: "Duplicate of #\(first)")
        }
        return entry.status.title
    }

    // MARK: Lookup

    private var lookup: some View {
        let name = query.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: Symbol.lookup)
                    .font(DS.Font.inlineIcon)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .accessibilityHidden(true)
                TextField(text: $query, prompt: Text("Command name, e.g. node")) {
                    Text("Look up a command")
                }
                .textFieldStyle(.dsField)
                .font(DS.Font.monoBody)
                .autocorrectionDisabled()
                .accessibilityLabel(Text("Look up a command"))
            }
            if !name.isEmpty {
                let matches = lookup(name)
                if matches.chain.isEmpty && matches.offPath.isEmpty {
                    IconText(symbol: StatusKind.unknown.symbol, text: String(localized: "No command named \(name) was found in PATH."), tint: DS.Palette.textSecondary)
                } else {
                    if !matches.chain.isEmpty {
                        Text("Terminal runs the first match for \(name):")
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Palette.textSecondary)
                        ResolutionChainView(chain: matches.chain) { path in matches.owner(path) }
                    }
                    ForEach(matches.offPath, id: \.path) { ref in
                        HStack(spacing: DS.Space.s2) {
                            StatusLabel(kind: .notLinked, font: DS.Font.caption)
                            PathText(path: ref.path, color: DS.Palette.textSecondary)
                        }
                    }
                }
            } else {
                Text("Type a command to see every match in PATH order.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }

    private struct LookupResult {
        var chain: [ExecutableRef]
        var offPath: [ExecutableRef]
        var owners: [String: ToolInstallation]

        func owner(_ path: String) -> ToolInstallation? { owners[path] }
    }

    private func lookup(_ name: String) -> LookupResult {
        var chain: [ExecutableRef] = []
        var offPath: [ExecutableRef] = []
        var owners: [String: ToolInstallation] = [:]
        for tool in model.snapshot?.tools ?? [] {
            for installation in tool.installations {
                for ref in installation.executables where ref.name == name {
                    owners[ref.path] = installation
                    if ref.pathPriority != nil { chain.append(ref) } else { offPath.append(ref) }
                }
            }
        }
        chain.sort { ($0.pathPriority ?? .max, $0.path) < ($1.pathPriority ?? .max, $1.path) }
        return LookupResult(chain: chain, offPath: offPath, owners: owners)
    }
}
