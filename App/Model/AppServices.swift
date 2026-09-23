import AppKit
import CLIStateDomain
import SwiftUI

/// The one `AppModel` of this process, shared by the main window, Settings, the
/// menu bar extra and App Intents, so there is a single scan pipeline.
@MainActor
final class AppServices {
    static let shared = AppServices()

    /// `WindowGroup` id of the main window.
    static let mainWindowID = "main"

    let model: AppModel
    /// Captured from a live view (the menu bar icon or the main window); SwiftUI
    /// offers no other way to open a scene from AppKit or an intent.
    var openWindow: OpenWindowAction?

    private init() {
        model = AppModel(actions: CLIStateApp.makeActions())
    }

    /// Starts the model once per launch, then lets Shortcuts offer the scanned
    /// tools in "Open … in CLIState" phrases.
    func startLaunchPass() {
        let launchPass = model.startIfNeeded()
        Task {
            await launchPass.value
            CLIStateShortcuts.updateAppShortcutParameters()
        }
    }

    /// Brings the main window to the front, opening one if it was closed, and
    /// navigates to `route`.
    func showMainWindow(route: AppRoute? = nil) {
        switch route {
        case let .tool(id)?: model.show(tool: id)
        case let route?: model.route = route
        case nil: break
        }
        NSApp.activate()
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            openWindow(id: Self.mainWindowID)
            focusNewMainWindow()
        } else {
            // Re-opening the running app makes SwiftUI create a window when none is open.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        }
    }

    /// `openWindow` creates the window on a later pass and, when called from the
    /// menu bar extra or an intent, doesn't reliably bring it to the front.
    private func focusNewMainWindow() {
        Task {
            for _ in 0..<Self.focusAttempts {
                if let window = mainWindow {
                    window.makeKeyAndOrderFront(nil)
                    return
                }
                try? await Task.sleep(for: Self.focusRetryInterval)
            }
        }
    }

    private static let focusAttempts = 20
    private static let focusRetryInterval: Duration = .milliseconds(50)

    private var mainWindow: NSWindow? {
        NSApp.windows.first { window in
            guard let identifier = window.identifier?.rawValue, identifier.hasPrefix(Self.mainWindowID) else { return false }
            return window.isVisible || window.isMiniaturized
        }
    }
}

extension View {
    /// Keeps `AppServices.openWindow` usable after the main window closes.
    func capturesWindowOpener() -> some View {
        modifier(WindowOpenerCapture())
    }
}

private struct WindowOpenerCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            AppServices.shared.openWindow = openWindow
        }
    }
}
