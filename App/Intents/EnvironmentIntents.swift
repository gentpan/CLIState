import AppIntents
import CLIStateApplication
import CLIStateDomain
import Foundation

// Read-only intents. None of them updates or uninstalls anything: changes stay
// behind the in-app confirmation sheet.

/// Counts from "Scan Development Environment".
struct EnvironmentSummaryEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Environment Summary", table: "MenuBar"))

    @Property(title: LocalizedStringResource("Summary", table: "MenuBar"))
    var summary: String

    @Property(title: LocalizedStringResource("Tools", table: "MenuBar"))
    var toolCount: Int

    @Property(title: LocalizedStringResource("Updates Available", table: "MenuBar"))
    var updateCount: Int

    @Property(title: LocalizedStringResource("Issues", table: "MenuBar"))
    var issueCount: Int

    @Property(title: LocalizedStringResource("Critical Issues", table: "MenuBar"))
    var criticalIssueCount: Int

    @Property(title: LocalizedStringResource("Scanned At", table: "MenuBar"))
    var scannedAt: Date?

    init() {
        summary = ""
        toolCount = 0
        updateCount = 0
        issueCount = 0
        criticalIssueCount = 0
    }

    @MainActor
    init(digest: EnvironmentDigest, scannedAt: Date) {
        self.init()
        summary = MenuBarText.scanSummary(digest)
        toolCount = digest.toolCount
        updateCount = digest.updates.count
        issueCount = digest.issues.total
        criticalIssueCount = digest.issues.critical
        self.scannedAt = scannedAt
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: .verbatim(summary))
    }
}

struct ScanEnvironmentIntent: AppIntent {
    static let title = LocalizedStringResource("Scan Development Environment", table: "MenuBar")
    static let description = IntentDescription(
        LocalizedStringResource("Rescans installed CLI tools, PATH and package managers, and returns how many tools, updates and issues CLI State found. Doesn't check the network for new versions.", table: "MenuBar")
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<EnvironmentSummaryEntity> & ProvidesDialog {
        let model = AppServices.shared.model
        let snapshot = try await model.scanForShortcut(.fast)
        let summary = EnvironmentSummaryEntity(digest: model.environmentDigest, scannedAt: snapshot.capturedAt)
        return .result(value: summary, dialog: IntentDialog(.verbatim(summary.summary)))
    }
}

struct CheckForUpdatesIntent: AppIntent {
    static let title = LocalizedStringResource("Check for CLI Updates", table: "MenuBar")
    static let description = IntentDescription(
        LocalizedStringResource("Checks package managers and installers for newer versions and returns the tools that can be updated. Nothing is installed.", table: "MenuBar")
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ToolUpdateEntity]> & ProvidesDialog {
        let model = AppServices.shared.model
        let snapshot = try await model.scanForShortcut(.deep)
        let updates = model.environmentDigest.updates
        let entities = updates.map { ToolUpdateEntity(update: $0, tool: snapshot.tool($0.toolID)) }
        let dialog = updates.isEmpty
            ? String(localized: "All tools are up to date.", table: "MenuBar")
            : String(localized: "Updates available (\(updates.count)): \(updates.map(\.name).formatted(.list(type: .and))).", table: "MenuBar")
        return .result(value: entities, dialog: IntentDialog(.verbatim(dialog)))
    }
}

struct WhichCommandIntent: AppIntent {
    static let title = LocalizedStringResource("Look Up Command", table: "MenuBar")
    static let description = IntentDescription(
        LocalizedStringResource("Shows which executable the terminal runs for a command, its version, how it was installed and which other copies it shadows. Uses the latest scan and runs nothing.", table: "MenuBar")
    )

    @Parameter(title: LocalizedStringResource("Command", table: "MenuBar"), inputOptions: String.IntentInputOptions(keyboardType: .default, capitalizationType: .none, autocorrect: false))
    var command: String

    static var parameterSummary: some ParameterSummary {
        Summary("Look up \(\.$command)", table: "MenuBar")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CommandLookupEntity> & ProvidesDialog {
        let snapshot = try await AppServices.shared.model.snapshotForShortcut()
        let lookup = CommandLookup(command: command, in: snapshot)
        let entity = CommandLookupEntity(lookup: lookup, snapshot: snapshot)
        return .result(value: entity, dialog: IntentDialog(.verbatim(Self.dialog(for: lookup))))
    }

    @MainActor
    private static func dialog(for lookup: CommandLookup) -> String {
        guard let active = lookup.active else {
            if let offPath = lookup.offPath.first {
                return String(localized: "\(lookup.command) is installed at \(offPath.executable.path) but isn't in PATH.", table: "MenuBar")
            }
            return String(localized: "No command named \(lookup.command) was found in PATH.", table: "MenuBar")
        }
        var lines = [String(localized: "\(lookup.command) runs \(active.executable.path)", table: "MenuBar")]
        lines.append(String(localized: "Version: \(active.version ?? "—") · Installed via \(active.provider.displayName)", table: "MenuBar"))
        if !lookup.shadowed.isEmpty {
            lines.append(String(localized: "Shadows: \(lookup.shadowed.map(\.executable.path).joined(separator: ", "))", table: "MenuBar"))
        }
        if let shadow = lookup.shellShadows.first {
            lines.append(shadowLine(shadow.kind, command: lookup.command))
        }
        return lines.joined(separator: "\n")
    }

    private static func shadowLine(_ kind: ShellShadow.Kind, command: String) -> String {
        switch kind {
        case .alias: String(localized: "An alias named \(command) runs before PATH.", table: "MenuBar")
        case .function: String(localized: "A shell function named \(command) runs before PATH.", table: "MenuBar")
        case .builtin, .reserved: String(localized: "\(command) is built into the shell, so PATH isn't used.", table: "MenuBar")
        case .hashed: String(localized: "The shell remembers an earlier location for \(command); run hash -r to forget it.", table: "MenuBar")
        }
    }
}

struct OpenToolIntent: AppIntent {
    static let title = LocalizedStringResource("Open Tool in CLI State", table: "MenuBar")
    static let description = IntentDescription(LocalizedStringResource("Opens CLI State with the tool selected.", table: "MenuBar"))
    static let openAppWhenRun = true

    @Parameter(title: LocalizedStringResource("Tool", table: "MenuBar"))
    var tool: ToolEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$tool)", table: "MenuBar")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let snapshot = try await AppServices.shared.model.snapshotForShortcut()
        guard let found = snapshot.tool(ToolID(tool.id)) else { throw ShortcutError.toolNotFound }
        AppServices.shared.showMainWindow(route: .tool(found.id))
        return .result()
    }
}
