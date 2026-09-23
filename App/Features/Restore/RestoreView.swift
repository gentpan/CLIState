import CLIStateApplication
import CLIStateDomain
import SwiftUI

/// 环境迁移: export this Mac, import a profile, or start from a template (Lane N).
struct RestoreView: View {
    @Environment(AppModel.self) private var model
    @Environment(RestoreModel.self) private var restore
    @Environment(AIModel.self) private var ai

    var body: some View {
        @Bindable var restore = restore
        VStack(spacing: 0) {
            HStack {
                DSTabs(selection: $restore.tab, options: [.export, .importFile, .templates], title: RestoreText.pageTitle) { tab in
                    switch tab {
                    case .export: String(localized: "Export This Mac", table: "Restore")
                    case .importFile: String(localized: "Import from File", table: "Restore")
                    case .templates: String(localized: "Templates", table: "Restore")
                    }
                }
                .frame(maxWidth: DS.Layout.tabsMaxWidth)
                Spacer()
            }
            .padding(.horizontal, DS.Space.s6)
            .padding(.vertical, DS.Space.s2)
            .frame(minHeight: DS.Layout.pageHeaderMinHeight)
            Divider()
            // Fills the rest, so an empty state centers itself instead of the whole page.
            Group {
                switch restore.tab {
                case .export: RestoreExportView()
                case .importFile: RestoreImportView()
                case .templates: RestoreTemplatesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .dsPageTitle(Text(verbatim: RestoreText.pageTitle), symbol: "square.and.arrow.down.on.square")
        #if DEBUG
        .task { await RestoreDebugLaunch.apply(restore: restore, model: model, ai: ai) }
        .debugSelection { values in
            switch values["restore"] {
            case "export": restore.tab = .export
            case "import": restore.tab = .importFile
            case "templates": restore.tab = .templates
            default: break
            }
        }
        #endif
    }
}

// MARK: - Export

struct RestoreExportView: View {
    @Environment(AppModel.self) private var model
    @Environment(RestoreModel.self) private var restore

    var body: some View {
        @Bindable var restore = restore
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s4) {
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        Text("Save what's installed on this Mac", tableName: "Restore")
                            .font(DS.Font.title)
                            .foregroundStyle(DS.Palette.textPrimary)
                        Text("Only packages you installed yourself through Homebrew, npm, pnpm, uv, pipx or Cargo are included. Dependencies, system tools, paths, environment variables and secrets never are.", tableName: "Restore")
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: DS.Space.s3) {
                        VStack(alignment: .leading, spacing: DS.Space.s2) {
                            Text("Name", tableName: "Restore")
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Palette.textSecondary)
                            TextField(text: $restore.profileName, prompt: Text("My Mac", tableName: "Restore")) {
                                Text("Name", tableName: "Restore")
                            }
                            .textFieldStyle(.dsField)
                            .frame(maxWidth: .infinity)
                        }
                        VStack(alignment: .leading, spacing: DS.Space.s2) {
                            Text("Note", tableName: "Restore")
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Palette.textSecondary)
                            TextField(text: $restore.profileNote, prompt: Text("Optional", tableName: "Restore")) {
                                Text("Note", tableName: "Restore")
                            }
                            .textFieldStyle(.dsField)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .dsCard()

                    content
                }
                .padding(DS.Space.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let draft = restore.exportDraft, !draft.items.isEmpty {
                Divider()
                footer(total: draft.items.count)
            }
        }
        .task(id: model.snapshot?.capturedAt) {
            await restore.loadExport(model: model)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let draft = restore.exportDraft {
            if draft.items.isEmpty {
                EmptyStateView(LocalizedStringKey(String(localized: "Nothing to export", table: "Restore")), symbol: RestoreSymbol.export, message: String(localized: "CLI State didn't find packages you installed yourself with a supported package manager.", table: "Restore"))
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(Self.groups(draft.items), id: \.provider) { group in
                    ExportGroupCard(provider: group.provider, items: group.items)
                }
            }
        } else {
            HStack(spacing: DS.Space.s2) {
                ProgressView().controlSize(.small)
                Text("Reading the latest scan…", tableName: "Restore")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }

    private func footer(total: Int) -> some View {
        HStack(spacing: DS.Space.s3) {
            let count = restore.exportSelection.count
            Text("\(count) of \(total) selected", tableName: "Restore")
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.textSecondary)
                .monospacedDigit()
            Spacer()
            Button {
                restore.saveBrewfile(model: model)
            } label: {
                Label {
                    Text("Export Brewfile…", tableName: "Restore")
                } icon: {
                    Image(systemName: RestoreSymbol.brewfile)
                }
            }
            .disabled(!restore.canExportBrewfile)
            .help(Text("tap, brew and cask lines for `brew bundle`", tableName: "Restore"))
            Button {
                restore.saveProfile(model: model)
            } label: {
                Label {
                    Text("Save Profile…", tableName: "Restore")
                } icon: {
                    Image(systemName: RestoreSymbol.export)
                }
            }
            .buttonStyle(.dsPrimary)
            .disabled(count == 0)
        }
        .padding(DS.Space.s4)
        .background(DS.Palette.panelPrimary)
    }

    static func groups(_ items: [ProfileItem]) -> [(provider: ProfileProvider, items: [ProfileItem])] {
        var order: [ProfileProvider] = []
        var grouped: [ProfileProvider: [ProfileItem]] = [:]
        for item in items {
            if grouped[item.provider] == nil { order.append(item.provider) }
            grouped[item.provider, default: []].append(item)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }
}

private struct ExportGroupCard: View {
    let provider: ProfileProvider
    let items: [ProfileItem]
    @Environment(AppModel.self) private var model
    @Environment(RestoreModel.self) private var restore

    var body: some View {
        let allSelected = items.allSatisfy { !restore.exportExcluded.contains($0.id) }
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s2) {
                IconText(symbol: Symbol.provider(provider.providerID ?? .standalone), text: RestoreText.providerTitle(provider), tint: DS.Palette.textSecondary, textColor: DS.Palette.textPrimary, font: DS.Font.headline)
                Text(verbatim: "\(items.count)")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .monospacedDigit()
                Spacer()
                Button {
                    for item in items {
                        if allSelected { restore.exportExcluded.insert(item.id) } else { restore.exportExcluded.remove(item.id) }
                    }
                } label: {
                    allSelected ? Text("Deselect All", tableName: "Restore") : Text("Select All", tableName: "Restore")
                }
                .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                ForEach(items) { item in
                    Toggle(isOn: Binding(
                        get: { !restore.exportExcluded.contains(item.id) },
                        set: { isOn in if isOn { restore.exportExcluded.remove(item.id) } else { restore.exportExcluded.insert(item.id) } }
                    )) {
                        RestoreItemLabel(item: item, snapshot: model.snapshot) {
                            if item.pinned {
                                IconText(symbol: RestoreSymbol.pin, text: String(localized: "Pinned", table: "Restore"), font: DS.Font.caption)
                            }
                            Text(verbatim: item.version ?? "—")
                                .font(DS.Font.mono)
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .dsCard()
    }
}

/// Name, package name and tap, with trailing details.
struct RestoreItemLabel<Trailing: View>: View {
    let item: ProfileItem
    let snapshot: EnvironmentSnapshot?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let name = RestoreText.displayName(item, snapshot: snapshot)
        HStack(alignment: .center, spacing: DS.Space.s4) {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text(verbatim: name)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if item.qualifiedName != name {
                    Text(verbatim: item.qualifiedName)
                        .font(DS.Font.mono)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if item.provider == .homebrewCask {
                    Text(verbatim: "cask")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .font(DS.Font.mono)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: DS.Layout.versionColumnWidth, alignment: .trailing)
        }
        .padding(.vertical, DS.Space.s2)
        .frame(minHeight: DS.Layout.tableRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
