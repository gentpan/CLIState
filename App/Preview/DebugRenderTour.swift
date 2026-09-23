import SwiftUI

#if DEBUG
import AppKit
import CLIStateDomain

/// `-CLIStateRenderTour /dir` walks every page of the app in one launch and writes
/// each as a PNG (window chrome included) at the default and a narrow window size,
/// plus the Settings panes, the confirmation and leftover sheets and the AI window.
/// Rendering goes through `cacheDisplay`, so AppKit-backed tables appear and no
/// screen-recording permission is needed.
@MainActor
enum DebugRenderTour {
    /// Posted to switch view-local state the tour can't reach through `AppModel`.
    static let selectionNotification = Notification.Name("CLIStateDebugSelect")

    private struct Stop {
        let name: String
        let apply: @MainActor (AppModel) async -> Void
        var settle: Duration = .seconds(1.5)
    }

    static func run(model: AppModel, openSettings: OpenSettingsAction, directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let window = await waitForMainWindow() else { return }
        let stops: [Stop] = [
            Stop(name: "overview") { $0.route = .overview },
            Stop(name: "tools") { $0.route = .tools(.all); $0.toolSelection = nil; $0.isInspectorPresented = false },
            Stop(name: "tools-detail") { $0.show(tool: "node") },
            Stop(name: "tools-filtered") { $0.toolSelection = nil; $0.isInspectorPresented = false; $0.route = .tools(ToolFilter(category: .runtime, provider: .homebrew)) },
            Stop(name: "updates") { $0.route = .updates },
            Stop(name: "issues") { $0.route = .issues },
            Stop(name: "path") { $0.route = .path },
            Stop(name: "cleanup", apply: { $0.route = .cleanup }, settle: .seconds(3)),
            Stop(name: "restore-export") { $0.route = .restore; select(["restore": "export"]) },
            Stop(name: "restore-import") { _ in select(["restore": "import"]) },
            Stop(name: "restore-templates") { _ in select(["restore": "templates"]) },
            Stop(name: "history-changes") { $0.route = .history; select(["history": "changes"]) },
            Stop(name: "history-operations") { _ in select(["history": "operations"]) },
        ]

        for (label, size) in [("wide", NSSize(width: DS.Layout.windowDefaultWidth, height: DS.Layout.windowDefaultHeight)), ("narrow", NSSize(width: DS.Layout.windowMinWidth, height: DS.Layout.windowMinHeight))] {
            window.setContentSize(size)
            try? await Task.sleep(for: .seconds(1))
            for stop in stops {
                await stop.apply(model)
                try? await Task.sleep(for: stop.settle)
                write(window, to: directory.appendingPathComponent("\(label)-\(stop.name).png"))
            }
        }

        // Sheets on the main window.
        model.route = .updates
        if let tool = model.snapshot?.tool("php") {
            model.requestUpdate(tool.installations.filter { $0.hasUpdate && $0.capabilities.canUpdate }.map { InstallationRef(toolID: tool.id, installationID: $0.id) })
            if await waitForSheet(on: window) { write(window.attachedSheet, to: directory.appendingPathComponent("sheet-confirm-update.png")) }
            model.pendingOperation = nil
            try? await Task.sleep(for: .seconds(1))
        }
        if let tool = model.snapshot?.tool("node"), let installation = ToolMenuText.uninstallable(tool).first {
            model.reviewLeftovers(LeftoverReview(toolID: tool.id, mode: .uninstall(InstallationRef(toolID: tool.id, installationID: installation.id))))
            if await waitForSheet(on: window) {
                try? await Task.sleep(for: .seconds(1.5))
                write(window.attachedSheet, to: directory.appendingPathComponent("sheet-leftovers.png"))
            }
            model.leftoverReview = nil
            try? await Task.sleep(for: .seconds(1))
        }

        // Settings window, every pane.
        openSettings()
        try? await Task.sleep(for: .seconds(1.5))
        for pane in ["general", "updates", "scanning", "ai", "about"] {
            UserDefaults.standard.set(pane, forKey: "SettingsPane")
            try? await Task.sleep(for: .seconds(1))
            if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== window && !($0 is NSPanel) && $0.contentView != nil && $0.frame.width >= DS.Layout.settingsWidth - 40 && $0.frame.width <= DS.Layout.settingsWidth + 80 }) {
                write(settings, to: directory.appendingPathComponent("settings-\(pane).png"))
            }
        }

        // Any other window (AI explanation opened by -CLIStateAIExplain).
        for other in NSApp.windows where other.isVisible && other !== window && other.contentView != nil {
            let title = other.title.isEmpty ? "window-\(other.windowNumber)" : "window-\(other.title.replacingOccurrences(of: " ", with: "-"))"
            write(other, to: directory.appendingPathComponent("\(title).png"))
        }
        try? "done\n".write(to: directory.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }

    private static func select(_ values: [String: String]) {
        NotificationCenter.default.post(name: selectionNotification, object: nil, userInfo: values)
    }

    private static func waitForMainWindow() async -> NSWindow? {
        for _ in 0..<40 {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.contentView != nil }) { return window }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private static func waitForSheet(on window: NSWindow) async -> Bool {
        for _ in 0..<40 {
            if window.attachedSheet != nil { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// The theme frame (content view's superview) includes the title bar and toolbar.
    private static func write(_ window: NSWindow?, to url: URL) {
        guard let window, let content = window.contentView, let view = content.superview ?? Optional(content) else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif

extension View {
    /// Lets the debug render tour switch view-local state (segments, tabs); no-op in Release.
    @ViewBuilder
    func debugSelection(_ handler: @escaping ([String: String]) -> Void) -> some View {
        #if DEBUG
        onReceive(NotificationCenter.default.publisher(for: DebugRenderTour.selectionNotification)) { notification in
            handler((notification.userInfo as? [String: String]) ?? [:])
        }
        #else
        self
        #endif
    }
}
