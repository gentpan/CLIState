import AppKit
import CLIStateDomain
import SwiftUI

/// Every action for one tool, driven only by its installations' capabilities.
/// Used as the Tools table's context menu and as Tool Detail's "More" menu.
struct ToolContextMenu: View {
    enum Placement {
        case table, detail
    }

    let tool: Tool
    let model: AppModel
    var placement: Placement = .table

    var body: some View {
        if placement == .table {
            Button(ToolMenuText.showDetails) { model.show(tool: tool.id) }
            // Tool Detail has its own header button.
            ExplainWithAIMenuItem(tool: tool)
            Divider()
        }
        updateItems
        policyMenu
        serviceMenu
        Divider()
        removalItems
        Divider()
        fileItems
    }

    // MARK: Updates

    private var updatable: [ToolInstallation] {
        tool.installations.filter { $0.hasUpdate && ToolActionsAvailable.canUpdate($0) }
    }

    @ViewBuilder
    private var updateItems: some View {
        let updatable = self.updatable
        if updatable.count == 1, let installation = updatable.first {
            Button {
                model.requestUpdate([ref(installation)])
            } label: {
                Label(ToolMenuText.update(to: installation.latest?.value.rawValue), systemImage: Symbol.update)
            }
            .disabled(model.isPreparingOperation)
        } else if updatable.count > 1 {
            Menu {
                ForEach(updatable) { installation in
                    Button(ToolMenuText.installationTitle(installation, arrowTo: installation.latest?.value.rawValue)) {
                        model.requestUpdate([ref(installation)])
                    }
                }
                Divider()
                Button(ToolMenuText.updateAll(updatable.count)) {
                    model.requestUpdate(updatable.map(ref))
                }
            } label: {
                Label(ToolMenuText.updateMenu, systemImage: Symbol.update)
            }
            .disabled(model.isPreparingOperation)
        }

        let skippable = tool.installations.filter { $0.hasUpdate && $0.latest != nil }
        if skippable.count == 1, let installation = skippable.first {
            let item = UpdateItem(tool: tool, installation: installation)
            let skipped = model.isSkipped(item)
            Button {
                skipped ? model.unskip(item) : model.skip(item)
            } label: {
                Label(skipped ? ToolMenuText.stopSkipping(item.latestVersion ?? "") : ToolMenuText.skipThisVersion, systemImage: Symbol.skip)
            }
        } else if skippable.count > 1 {
            Menu {
                ForEach(skippable) { installation in
                    let item = UpdateItem(tool: tool, installation: installation)
                    Toggle(ToolMenuText.installationTitle(installation, arrowTo: item.latestVersion), isOn: Binding(
                        get: { model.isSkipped(item) },
                        set: { $0 ? model.skip(item) : model.unskip(item) }
                    ))
                }
            } label: {
                Label(ToolMenuText.skipThisVersion, systemImage: Symbol.skip)
            }
        }
    }

    // MARK: Settings

    @ViewBuilder
    private var policyMenu: some View {
        if tool.installations.contains(where: { $0.capabilities.canUpdate }) {
            let override = model.preferences.toolPolicies[tool.id]
            let inherited = model.preferences.providerPolicies[tool.primaryProvider ?? .standalone] ?? model.preferences.defaultPolicy
            Menu {
                ForEach(AutoUpdatePolicy.allCases, id: \.self) { policy in
                    Toggle(policy.title, isOn: Binding(
                        get: { override == policy },
                        set: { if $0 { model.setPolicy(policy, for: tool.id) } }
                    ))
                }
                Divider()
                Toggle(ToolMenuText.useDefault(inherited.title), isOn: Binding(
                    get: { override == nil },
                    set: { if $0 { model.setPolicy(nil, for: tool.id) } }
                ))
            } label: {
                Label(ToolMenuText.autoUpdate, systemImage: Symbol.automatic)
            }
        }
    }

    @ViewBuilder
    private var serviceMenu: some View {
        if let service = tool.service {
            let caps = (tool.installations.first { $0.id == service.installationID } ?? tool.primaryInstallation)?.capabilities ?? .none
            if caps.canStart || caps.canStop || caps.canRestart {
                Menu {
                    ForEach(ServiceAction.allCases, id: \.self) { action in
                        if Self.allows(action, caps) {
                            Button {
                                model.requestService(action, service: service)
                            } label: {
                                Label(action.title, systemImage: action.symbol)
                            }
                        }
                    }
                } label: {
                    Label(ToolMenuText.service(service.status), systemImage: Symbol.service)
                }
                .disabled(model.isPreparingOperation)
            }
        }
    }

    private static func allows(_ action: ServiceAction, _ caps: ToolCapabilities) -> Bool {
        switch action {
        case .start: caps.canStart
        case .stop: caps.canStop
        case .restart: caps.canRestart
        }
    }

    // MARK: Removal

    @ViewBuilder
    private var removalItems: some View {
        let uninstallable = ToolMenuText.uninstallable(tool)
        if uninstallable.count == 1, let installation = uninstallable.first {
            Button(role: .destructive) {
                model.requestUninstall(ref(installation))
            } label: {
                Label(ToolMenuText.uninstall, systemImage: Symbol.uninstall)
            }
            Button(role: .destructive) {
                model.reviewLeftovers(LeftoverReview(toolID: tool.id, mode: .uninstall(ref(installation))))
            } label: {
                Label(ToolMenuText.uninstallAndCleanUp, systemImage: Symbol.cleanup)
            }
        } else if uninstallable.count > 1 {
            Menu {
                ForEach(uninstallable) { installation in
                    Button(ToolMenuText.installationTitle(installation)) { model.requestUninstall(ref(installation)) }
                }
            } label: {
                Label(ToolMenuText.uninstallMenu, systemImage: Symbol.uninstall)
            }
            Menu {
                ForEach(uninstallable) { installation in
                    Button(ToolMenuText.installationTitle(installation)) {
                        model.reviewLeftovers(LeftoverReview(toolID: tool.id, mode: .uninstall(ref(installation))))
                    }
                }
            } label: {
                Label(ToolMenuText.uninstallAndCleanUpMenu, systemImage: Symbol.cleanup)
            }
        }

        Button {
            model.reviewLeftovers(LeftoverReview(toolID: tool.id, mode: .cleanUp))
        } label: {
            Label(ToolMenuText.cleanUpLeftovers, systemImage: Symbol.cleanup)
        }

        let trashable = tool.installations.filter { $0.capabilities.canMoveToTrash && !$0.isSystemManaged && $0.primaryExecutable != nil }
        if trashable.count == 1, let path = trashable.first?.primaryExecutable?.path {
            Button(role: .destructive) {
                model.requestMoveToTrash(paths: [path], toolID: tool.id)
            } label: {
                Label(ToolMenuText.moveToTrash, systemImage: Symbol.trash)
            }
        } else if trashable.count > 1 {
            Menu {
                ForEach(trashable) { installation in
                    if let path = installation.primaryExecutable?.path {
                        Button(PathRedaction.abbreviatingHome(path, home: model.homeDirectory)) {
                            model.requestMoveToTrash(paths: [path], toolID: tool.id)
                        }
                    }
                }
            } label: {
                Label(ToolMenuText.moveToTrashMenu, systemImage: Symbol.trash)
            }
        }
    }

    // MARK: Files

    @ViewBuilder
    private var fileItems: some View {
        let installation = tool.primaryInstallation
        if let path = installation?.primaryExecutable?.path ?? installation?.installPrefix {
            Button {
                Finder.reveal(path)
            } label: {
                Label(ToolMenuText.revealInFinder, systemImage: Symbol.reveal)
            }
            Button {
                Self.copy(path)
            } label: {
                Label(ToolMenuText.copyPath, systemImage: Symbol.copy)
            }
        }
        if let version = installation?.version?.value.rawValue {
            Button {
                Self.copy(version)
            } label: {
                Label(ToolMenuText.copyVersion, systemImage: Symbol.copy)
            }
        }
    }

    private func ref(_ installation: ToolInstallation) -> InstallationRef {
        InstallationRef(toolID: tool.id, installationID: installation.id)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension Symbol {
    static let moreActions = "ellipsis.circle"
}

/// Strings for the tool menu and leftover cleanup, kept in `Tools.xcstrings`.
enum ToolMenuText {
    static var showDetails: String { String(localized: "Show Details", table: "Tools") }
    static var updateMenu: String { String(localized: "Update", table: "Tools") }
    static var skipThisVersion: String { String(localized: "Skip This Version", table: "Tools") }
    static var autoUpdate: String { String(localized: "Auto-Update", table: "Tools") }
    static var uninstall: String { String(localized: "Uninstall…", table: "Tools") }
    static var uninstallMenu: String { String(localized: "Uninstall", table: "Tools") }
    static var uninstallAndCleanUp: String { String(localized: "Uninstall and Clean Up…", table: "Tools") }
    static var uninstallAndCleanUpMenu: String { String(localized: "Uninstall and Clean Up", table: "Tools") }
    static var cleanUpLeftovers: String { String(localized: "Clean Up Leftovers…", table: "Tools") }
    static var moveToTrash: String { String(localized: "Move to Trash…", table: "Tools") }
    static var moveToTrashMenu: String { String(localized: "Move to Trash", table: "Tools") }
    static var revealInFinder: String { String(localized: "Reveal in Finder", table: "Tools") }
    static var copyPath: String { String(localized: "Copy Path", table: "Tools") }
    static var copyVersion: String { String(localized: "Copy Version", table: "Tools") }
    static var moreActions: String { String(localized: "More", table: "Tools") }

    static func update(to version: String?) -> String {
        guard let version else { return updateMenu }
        return String(localized: "Update to \(version)", table: "Tools")
    }

    static func updateAll(_ count: Int) -> String {
        String(localized: "Update All \(count)", table: "Tools")
    }

    static func stopSkipping(_ version: String) -> String {
        String(localized: "Stop Skipping \(version)", table: "Tools")
    }

    static func useDefault(_ policy: String) -> String {
        String(localized: "Use Default (\(policy))", table: "Tools")
    }

    static func service(_ status: ServiceStatus) -> String {
        switch status {
        case .running: String(localized: "Service (Running)", table: "Tools")
        case .stopped: String(localized: "Service (Stopped)", table: "Tools")
        default: String(localized: "Service", table: "Tools")
        }
    }

    /// `Homebrew · 8.5.7`, or `Homebrew · 8.5.7 → 8.5.10`.
    static func installationTitle(_ installation: ToolInstallation, arrowTo latest: String? = nil) -> String {
        var title = "\(installation.ownership.provider.displayName) · \(installation.versionText)"
        if let latest { title += " → \(latest)" }
        return title
    }

    /// Installations a provider may remove: confirmed, capable, not macOS's.
    static func uninstallable(_ tool: Tool) -> [ToolInstallation] {
        tool.installations.filter(ToolActionsAvailable.canUninstall)
    }
}
