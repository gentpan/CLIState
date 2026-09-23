import CLIStateDomain
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        GliderNavigation(groups: groups, selection: selection, footer: [
            .init(id: "settings", title: "Settings", symbol: Symbol.settings, accessibilityHint: Text("Opens the Settings window")) {
                openSettings.bringToFront()
            },
        ])
    }

    /// Task-oriented pages only. Categories and "Installed via" are filters on
    /// the Tools page, so they no longer repeat here.
    private var groups: [GliderNavigation<AppRoute>.Group] {
        let updateCount = model.updateItems.count
        let issueCount = model.issues.count
        return [
            .init(id: "main", title: nil, items: [
                .init(id: .overview, title: "Overview", symbol: Symbol.overview),
                .init(id: .tools(.all), title: "Tools", symbol: Symbol.tools),
                .init(id: .discover, title: "Discover", symbol: "safari"),
                .init(id: .updates, title: "Updates", symbol: Symbol.updates, badge: updateCount, accessibilityValue: Text("\(updateCount) updates")),
                .init(id: .issues, title: "Issues", symbol: Symbol.issues, badge: issueCount, accessibilityValue: Text("\(issueCount) issues")),
            ]),
            .init(id: "environment", title: "Environment", items: [
                .init(id: .path, title: "PATH", symbol: Symbol.path),
                .init(id: .cleanup, title: "Cleanup", symbol: Symbol.cleanup),
                .init(id: .restore, title: LocalizedStringKey(RestoreText.pageTitle), symbol: RestoreSymbol.page),
                .init(id: .history, title: "History", symbol: Symbol.history),
            ]),
        ]
    }

    private var selection: Binding<AppRoute?> {
        Binding(
            get: { model.route?.sidebarRoute },
            set: { newValue in
                guard let newValue, newValue != model.route?.sidebarRoute else { return }
                model.route = newValue
            }
        )
    }
}
