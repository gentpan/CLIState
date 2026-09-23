import AppKit
import CLIStateApplication
import CLIStateDomain
import SwiftUI

@main
struct CLIStateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Shared with the menu bar extra and App Intents (`AppServices`).
    @State private var model = AppServices.shared.model
    @State private var updater = AppUpdater()
    @State private var ai = AIModel()
    @State private var restore = RestoreModel()

    /// Real scanning by default. `-CLIStateSampleData YES` uses the bundled sample
    /// snapshot (screenshots, UI work without touching the machine).
    @MainActor
    static func makeActions() -> any AppActions {
        if UserDefaults.standard.bool(forKey: "CLIStateSampleData") { return PreviewActions() }
        return LiveActions(environment: AppEnvironment.live())
    }

    var body: some Scene {
        WindowGroup(id: AppServices.mainWindowID) {
            RootView()
                .environment(model)
                .environment(updater)
                .environment(ai)
                .environment(restore)
                .aiLaunchOptions()
                .capturesWindowOpener()
                .frame(minWidth: DS.Layout.windowMinWidth, minHeight: DS.Layout.windowMinHeight)
        }
        .defaultSize(width: DS.Layout.windowDefaultWidth, height: DS.Layout.windowDefaultHeight)
        .commands {
            EnvironmentCommands(model: model)
            CommandGroup(after: .appInfo) {
                Button("Check for CLI State Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        AIExplanationScene(model: model, ai: ai)

        MenuBarScene(model: model)

        Settings {
            SettingsView()
                .environment(model)
                .environment(updater)
                .environment(ai)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window exists, so nothing flashes in the wrong appearance.
        DisplaySettings.load(from: .standard).appearance.apply()
        // Thin overlay scroll bars even when System Settings says "Always" or a mouse
        // is connected (user request: the legacy bars were too heavy). The app's own
        // domain overrides the global `AppleShowScrollBars`; read before any scroller exists.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also when no window opens, e.g. a Shortcut launched the app in the background.
        AppServices.shared.startLaunchPass()
    }

    /// Stays running after the last window closes, for the menu bar extra and the daily check.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct EnvironmentCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Environment") {
            Button("Refresh") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isScanning)

            Button("Check for Updates") {
                Task { await model.checkForUpdates() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.isScanning)

            Divider()

            Button(model.isActivityExpanded ? LocalizedStringKey("Hide Activity") : LocalizedStringKey("Show Activity")) {
                model.isActivityExpanded.toggle()
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .disabled(model.activity.isEmpty)
        }
    }
}
