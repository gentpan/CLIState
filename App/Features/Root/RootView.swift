import CLIStateDomain
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: DS.Layout.sidebarMin, ideal: DS.Layout.sidebarIdeal)
        } detail: {
            VStack(spacing: 0) {
                DetailView(route: model.route ?? .overview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !model.activity.isEmpty {
                    ActivityDrawer()
                }
            }
            .buttonStyle(.dsSecondary)
            .tint(DS.Palette.primary)
            .background(DS.Palette.background)
            // Keep the native toolbar background so empty titlebar space remains draggable.
            .toolbar {
                if case .tools = model.route ?? .overview, model.isInspectorPresented {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.isInspectorPresented = false
                            // Clearing selection lets the same row reopen its details.
                            model.toolSelection = nil
                        } label: {
                            Label("Back to list", systemImage: "xmark.circle")
                        }
                        .labelStyle(.iconOnly)
                        .help(Text("Close details and return to the full list"))
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    ScanButton()
                    SettingsButton()
                }
            }
        }
        .environment(\.homeDirectory, model.homeDirectory)
        .sheet(item: $model.pendingOperation) { operation in
            ConfirmationSheet(operation: operation)
                .environment(\.homeDirectory, model.homeDirectory)
                .buttonStyle(.dsSecondary)
        }
        .leftoverReviewSheet()
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
        .task {
            await model.startIfNeeded().value
            #if DEBUG
            await DebugLaunchOptions.apply(to: model, openSettings: openSettings)
            #endif
        }
    }
}

private struct ScanButton: View {
    @Environment(AppModel.self) private var model

    /// Always a toolbar button, so the item keeps its size and padding while the
    /// spinner shows; a bare ProgressView sat flush against the group's edge.
    var body: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            if model.isScanning {
                Label {
                    Text("Scanning…")
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                Label("Refresh", systemImage: Symbol.refresh)
            }
        }
        .disabled(model.isScanning)
        .help(model.isScanning ? Text("Scanning…") : Text("Rescan the environment (⌘R)"))
    }
}

private struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings.bringToFront()
        } label: {
            Label("Settings", systemImage: Symbol.settings)
        }
        .accessibilityLabel(Text("Settings"))
        .help(Text("Settings (⌘,)"))
    }
}

struct DetailView: View {
    let route: AppRoute
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.snapshot == nil {
            ScanningPlaceholder()
        } else {
            switch route {
            case .overview: OverviewView()
            case .discover: DiscoverView()
            case let .tools(filter): ToolsView(filter: filter)
            case .tool: ToolsView(filter: .all)
            case .updates: UpdatesView()
            case .issues: IssuesView()
            case .path: PathView()
            case .cleanup: CleanupView()
            case .restore: RestoreView()
            case .history: HistoryView()
            }
        }
    }
}

private struct ScanningPlaceholder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.scanState == .failed {
            EmptyStateView("Scan failed", symbol: Symbol.needsAttention, message: String(localized: "CLI State couldn't read your shell environment. Make sure your shell starts without errors, then try again.")) {
                Button("Try Again") { Task { await model.refresh() } }
            }
        } else {
            VStack(spacing: DS.Space.s3) {
                ProgressView()
                Text("Scanning your environment…")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
