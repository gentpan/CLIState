import AppIntents
import CLIStateApplication
import CLIStateDomain
import Foundation

/// A tool from the latest snapshot, for "Open Tool" and Shortcuts parameters.
struct ToolEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("CLI Tool", table: "MenuBar"))
    static let defaultQuery = ToolEntityQuery()

    /// `ToolID` raw value.
    let id: String

    @Property(title: LocalizedStringResource("Name", table: "MenuBar"))
    var name: String

    @Property(title: LocalizedStringResource("Command", table: "MenuBar"))
    var command: String

    @Property(title: LocalizedStringResource("Version", table: "MenuBar"))
    var version: String?

    @Property(title: LocalizedStringResource("Installed Via", table: "MenuBar"))
    var installedVia: String?

    var displayRepresentation: DisplayRepresentation {
        let details = [version, installedVia].compactMap(\.self).joined(separator: " · ")
        return DisplayRepresentation(title: .verbatim(name), subtitle: details.isEmpty ? nil : .verbatim(details))
    }

    @MainActor
    init(tool: Tool) {
        id = tool.id.rawValue
        name = tool.identity.displayName
        command = tool.command
        version = tool.primaryInstallation?.version?.value.rawValue
        installedVia = tool.primaryProvider?.displayName
    }
}

struct ToolEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [ToolEntity.ID]) async throws -> [ToolEntity] {
        let snapshot = try await AppServices.shared.model.snapshotForShortcut()
        return identifiers.compactMap { snapshot.tool(ToolID($0)) }.map(ToolEntity.init(tool:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [ToolEntity] {
        let model = AppServices.shared.model
        _ = try await model.snapshotForShortcut()
        return ToolSearch.rank(model.visibleTools, query: string).map(ToolEntity.init(tool:))
    }

    @MainActor
    func suggestedEntities() async throws -> [ToolEntity] {
        let model = AppServices.shared.model
        _ = try await model.snapshotForShortcut()
        return ToolSearch.rank(model.visibleTools, query: "").map(ToolEntity.init(tool:))
    }
}

/// One available update, returned by "Check for CLI Updates".
struct ToolUpdateEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("CLI Update", table: "MenuBar"))

    @Property(title: LocalizedStringResource("Name", table: "MenuBar"))
    var name: String

    @Property(title: LocalizedStringResource("Installed Version", table: "MenuBar"))
    var installedVersion: String?

    @Property(title: LocalizedStringResource("Latest Version", table: "MenuBar"))
    var latestVersion: String?

    @Property(title: LocalizedStringResource("Installed Via", table: "MenuBar"))
    var installedVia: String

    @Property(title: LocalizedStringResource("Tool", table: "MenuBar"))
    var tool: ToolEntity?

    init() {
        name = ""
        installedVia = ""
    }

    @MainActor
    init(update: EnvironmentDigest.Update, tool: Tool?) {
        self.init()
        name = update.name
        installedVersion = update.installedVersion
        latestVersion = update.latestVersion
        installedVia = update.provider.displayName
        self.tool = tool.map(ToolEntity.init(tool:))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: .verbatim(name), subtitle: .verbatim("\(installedVersion ?? "—") → \(latestVersion ?? "—") · \(installedVia)"))
    }
}

/// Where a command resolves, returned by "Which Command".
struct CommandLookupEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Command Lookup", table: "MenuBar"))

    @Property(title: LocalizedStringResource("Command", table: "MenuBar"))
    var command: String

    @Property(title: LocalizedStringResource("Active Path", table: "MenuBar"))
    var activePath: String?

    @Property(title: LocalizedStringResource("Version", table: "MenuBar"))
    var version: String?

    @Property(title: LocalizedStringResource("Installed Via", table: "MenuBar"))
    var installedVia: String?

    @Property(title: LocalizedStringResource("Shadowed Paths", table: "MenuBar"))
    var shadowedPaths: [String]

    @Property(title: LocalizedStringResource("Not in PATH", table: "MenuBar"))
    var offPathPaths: [String]

    @Property(title: LocalizedStringResource("Tool", table: "MenuBar"))
    var tool: ToolEntity?

    init() {
        command = ""
        shadowedPaths = []
        offPathPaths = []
    }

    @MainActor
    init(lookup: CommandLookup, snapshot: EnvironmentSnapshot) {
        self.init()
        command = lookup.command
        activePath = lookup.active?.executable.path
        version = lookup.active?.version
        installedVia = lookup.active?.provider.displayName
        shadowedPaths = lookup.shadowed.map(\.executable.path)
        offPathPaths = lookup.offPath.map(\.executable.path)
        tool = (lookup.active ?? lookup.offPath.first).flatMap { snapshot.tool($0.toolID) }.map(ToolEntity.init(tool:))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: .verbatim(command), subtitle: activePath.map { .verbatim($0) })
    }
}
