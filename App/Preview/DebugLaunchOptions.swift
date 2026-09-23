#if DEBUG
import AppKit
import CLIStateDomain
import SwiftUI

/// Debug-only launch arguments for screenshots and manual QA, e.g.
/// `-CLIStateRoute tool:php -CLIStateAction update:php -CLIStateSearch opencode`.
/// `cleanup:<tool>` and `uninstall-clean:<tool>` open the leftover review sheet;
/// `menu:<tool>` pops up the tool's context menu so it can be screenshotted;
/// `uninstall-clean-confirm:<tool>` skips the review and opens the confirmation
/// with the default selection.
@MainActor
enum DebugLaunchOptions {
    static func apply(to model: AppModel, openSettings: OpenSettingsAction) async {
        let defaults = UserDefaults.standard
        if let route = defaults.string(forKey: "CLIStateRoute") {
            apply(route: route, to: model)
        }
        if let search = defaults.string(forKey: "CLIStateSearch") {
            model.searchText = search
        }
        if let action = defaults.string(forKey: "CLIStateAction") {
            await perform(action, model: model)
        }
        if defaults.bool(forKey: "CLIStateOpenSettings") {
            openSettings()
        }
        if let directory = defaults.string(forKey: "CLIStateRenderTour") {
            await DebugRenderTour.run(model: model, openSettings: openSettings, directory: URL(fileURLWithPath: directory))
        }
        // `-CLIStateRenderMenuBar /path.png [-AppleInterfaceStyle Dark]` writes the menu bar
        // panel to an image, since the panel itself can't be screenshotted from a script.
        if let path = defaults.string(forKey: "CLIStateRenderMenuBar") {
            renderMenuBar(model: model, to: URL(fileURLWithPath: path))
        }
        // `-CLIStateRenderOverview /path.png` renders the Overview page off screen.
        if let path = defaults.string(forKey: "CLIStateRenderOverview") {
            let page = OverviewView(scrolls: false)
                .environment(model)
                .buttonStyle(.dsSecondary)
                .frame(width: DS.Layout.windowDefaultWidth - DS.Layout.sidebarIdeal)
                .background(DS.Palette.background)
            write(ImageRenderer(content: page), to: URL(fileURLWithPath: path))
        }
    }

    private static func apply(route: String, to model: AppModel) {
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first ?? "", parts.count > 1 ? parts[1] : nil) {
        case ("tools", nil): model.route = .tools(.all)
        case ("runtimes", nil): model.route = .tools(ToolFilter(category: .runtime))
        case ("aiCLI", nil): model.route = .tools(ToolFilter(category: .aiCLI))
        case ("updates", nil): model.route = .updates
        case ("issues", nil): model.route = .issues
        case ("path", nil): model.route = .path
        case ("cleanup", nil): model.route = .cleanup
        case ("restore", nil): model.route = .restore
        case ("history", nil): model.route = .history
        case let ("tool", id?): model.show(tool: ToolID(id))
        case let ("provider", id?): model.route = .tools(ToolFilter(provider: ProviderID(id)))
        default: model.route = .overview
        }
    }

    private static func perform(_ action: String, model: AppModel) async {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        guard let name = parts.first else { return }
        // `update-all` takes no argument.
        let argument = parts.count > 1 ? parts[1] : ""
        switch name {
        case "update", "run-update":
            guard let tool = model.snapshot?.tool(ToolID(argument)) else { return }
            model.requestUpdate(tool.installations.filter { $0.hasUpdate && $0.capabilities.canUpdate }.map { InstallationRef(toolID: tool.id, installationID: $0.id) })
            if name == "run-update", let operation = await waitForPendingOperation(model) {
                model.confirm(operation)
                model.isActivityExpanded = true
            }
        case "select":
            // Goes to Tools, then opens the inspector after the table has laid out,
            // like clicking the sidebar and then a row.
            try? await Task.sleep(for: .seconds(2))
            model.route = .tools(.all)
            try? await Task.sleep(for: .seconds(2))
            model.toolSelection = ToolID(argument)
        case "update-all":
            model.requestUpdateAll()
        case "uninstall":
            guard let tool = model.snapshot?.tool(ToolID(argument)), let installation = tool.primaryInstallation else { return }
            model.requestUninstall(InstallationRef(toolID: tool.id, installationID: installation.id))
        case "cleanup":
            if let candidate = model.snapshot?.cleanupCandidates.first(where: { $0.id == argument }) {
                model.requestCleanup(candidate)
            } else if let tool = model.snapshot?.tool(ToolID(argument)) {
                model.reviewLeftovers(LeftoverReview(toolID: tool.id, mode: .cleanUp))
            }
        case "menu":
            guard let tool = model.snapshot?.tool(ToolID(argument)) else { return }
            model.toolSelection = tool.id
            try? await Task.sleep(for: .seconds(1))
            guard let view = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.contentView else { return }
            let menu = NSHostingMenu(rootView: ToolContextMenu(tool: tool, model: model))
            menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.width * 0.35, y: view.bounds.height * 0.3), in: view)
        case "uninstall-clean-confirm":
            guard let tool = model.snapshot?.tool(ToolID(argument)) else { return }
            let paths = await model.leftovers(for: tool.id).filter { !$0.containsUserData }.map(\.path)
            if let installation = ToolMenuText.uninstallable(tool).first {
                model.requestUninstall(InstallationRef(toolID: tool.id, installationID: installation.id), leftovers: paths)
            } else {
                model.requestCleanLeftovers(tool: tool.id, paths: paths)
            }
        case "uninstall-clean":
            guard let tool = model.snapshot?.tool(ToolID(argument)), let installation = ToolMenuText.uninstallable(tool).first else { return }
            model.reviewLeftovers(LeftoverReview(toolID: tool.id, mode: .uninstall(InstallationRef(toolID: tool.id, installationID: installation.id))))
        default:
            break
        }
    }

    private static func write<Content: View>(_ renderer: ImageRenderer<Content>, to url: URL) {
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    private static func renderMenuBar(model: AppModel, to url: URL) {
        let renderer = ImageRenderer(content: MenuBarContentView().environment(model))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        // The menu bar icon next to it, enlarged on a light and a dark strip.
        let icon = NSImage(size: NSSize(width: 4 * MenuBarLayout.iconCanvas + 20, height: MenuBarLayout.iconCanvas + 8), flipped: false) { rect in
            for (index, (image, ground)) in [(MenuBarIcon.plain, NSColor.white), (MenuBarIcon.badged, NSColor.white), (MenuBarIcon.plain, NSColor.black), (MenuBarIcon.badged, NSColor.black)].enumerated() {
                let cell = NSRect(x: CGFloat(index) * (MenuBarLayout.iconCanvas + 5), y: 0, width: MenuBarLayout.iconCanvas + 5, height: rect.height)
                ground.setFill()
                cell.fill()
                let tinted = NSImage(size: image.size, flipped: false) { bounds in
                    image.draw(in: bounds)
                    (ground == .white ? NSColor.black : NSColor.white).set()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: cell.minX + 2.5, y: 4, width: MenuBarLayout.iconCanvas, height: MenuBarLayout.iconCanvas))
            }
            return true
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(icon.size.width * 8), pixelsHigh: Int(icon.size.height * 8), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let bitmap {
            bitmap.size = icon.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            icon.draw(in: NSRect(origin: .zero, size: icon.size))
            NSGraphicsContext.restoreGraphicsState()
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url.deletingPathExtension().appendingPathExtension("icon.png"))
        }
    }

    private static func waitForPendingOperation(_ model: AppModel) async -> PreparedOperation? {
        for _ in 0..<50 {
            if let operation = model.pendingOperation { return operation }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}
#endif
