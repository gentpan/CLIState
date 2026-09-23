import CLIStateApplication
import SwiftUI

/// Menu bar extra (Settings › General › Show in menu bar). Renders from the
/// shared `AppModel`; it never scans or runs operations on its own.
struct MenuBarScene: Scene {
    let model: AppModel

    var body: some Scene {
        MenuBarExtra(isInserted: isInserted) {
            MenuBarContentView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }

    /// SwiftUI writes this back on every scene update; saving an unchanged value
    /// would invalidate the scene again and recurse.
    private var isInserted: Binding<Bool> {
        Binding(
            get: { model.displaySettings.showInMenuBar },
            set: { newValue in
                guard newValue != model.displaySettings.showInMenuBar else { return }
                model.updateDisplaySettings { $0.showInMenuBar = newValue }
            }
        )
    }
}

private struct MenuBarLabel: View {
    let model: AppModel

    private var updateCount: Int { model.updateItems.count }

    var body: some View {
        Image(nsImage: updateCount > 0 ? MenuBarIcon.badged : MenuBarIcon.plain)
            .accessibilityLabel(Text(verbatim: "CLI State"))
            .accessibilityValue(updateCount > 0 ? Text("\(updateCount) updates available", tableName: "MenuBar") : Text(verbatim: ""))
            .capturesWindowOpener()
    }
}
