import SwiftUI

struct DiscoverView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var category = "All"
    @State private var selected: Set<String> = []

    private var visible: [RecommendedTool] {
        RecommendedTool.catalog.filter {
            (category == "All" || $0.category == category) &&
            (search.isEmpty || [$0.name, $0.id, localized($0.category), localized($0.summary)]
                .contains { $0.localizedStandardContains(search) })
        }
    }
    private var pending: [RecommendedTool] {
        RecommendedTool.catalog.filter { selected.contains($0.id) && $0.installedTool(in: model.snapshot?.tools ?? []) == nil }
    }
    private var busy: Bool { model.isScanning || model.isOperationRunning || model.isPreparingOperation || model.isRefreshingMetadata }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s6) {
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    Text("Find your next tool").font(DS.Font.largeTitle)
                    Text("A curated starting point for your Mac. Choose tools by what you want to do.")
                        .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
                    Text("Installs use Homebrew. Existing installations are shown, including system tools.")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
                TextField("Search recommendations", text: $search).textFieldStyle(.dsField)
                DSTabs(selection: $category, options: ["All"] + RecommendedTool.categories,
                       title: localized("Categories"), label: localized)
                HStack(spacing: DS.Space.s3) {
                    Button("Select available tools") {
                        selected.formUnion(visible.filter { $0.installedTool(in: model.snapshot?.tools ?? []) == nil }.map(\.id))
                    }.buttonStyle(.dsSecondary)
                    if !selected.isEmpty {
                        Button("Clear selection") { selected.removeAll() }.buttonStyle(.dsSecondary)
                    }
                    Spacer()
                    if model.isPreparingOperation { ProgressView().controlSize(.small) }
                    Button { model.requestRecommendedInstall(pending) } label: {
                        Text("Review installation (\(pending.count))")
                    }.buttonStyle(.dsPrimary).disabled(pending.isEmpty || busy)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: DS.Layout.cardMinWidth), spacing: DS.Space.s4)], spacing: DS.Space.s4) {
                    ForEach(visible) { item in card(item) }
                }
                if visible.isEmpty {
                    Text("No matching recommendations").font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
                        .frame(maxWidth: .infinity).padding(DS.Space.s8)
                }
                Text("Curated by CLI State · Package details from Homebrew · Not a popularity ranking")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }.padding(DS.Space.s6)
        }
        .dsPageTitle(Text("Discover"), symbol: "safari")
    }

    private func card(_ item: RecommendedTool) -> some View {
        let installed = item.installedTool(in: model.snapshot?.tools ?? [])
        return VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack(spacing: DS.Space.s3) {
                Image(systemName: item.symbol).font(DS.Font.standaloneIcon).foregroundStyle(DS.Palette.highlight)
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    Text(item.name).font(DS.Font.toolTitle)
                    Text(localized(item.category)).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                if installed == nil {
                    Toggle("Select tool", isOn: Binding(get: { selected.contains(item.id) }, set: {
                        if $0 { selected.insert(item.id) } else { selected.remove(item.id) }
                    })).toggleStyle(.checkbox).labelsHidden().accessibilityLabel(Text("Select \(item.name)"))
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Palette.success).accessibilityLabel(Text("Installed"))
                }
            }
            Text(localized(item.summary)).font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: DS.Space.s12, alignment: .top)
            HStack {
                Link("Homebrew Formula", destination: item.sourceURL).font(DS.Font.caption)
                Spacer()
                if let installed {
                    Button("View installed") { model.show(tool: installed.id) }.buttonStyle(.dsSecondary)
                } else {
                    Button("Install…") { model.requestRecommendedInstall([item]) }
                        .buttonStyle(.dsPrimary).disabled(busy)
                }
            }
        }.dsCard(padding: DS.Space.s4)
    }

    private func localized(_ key: String) -> String { String(localized: String.LocalizationValue(key)) }
}
