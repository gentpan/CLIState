import CLIStateDomain
import Foundation

/// Filters of the Tools page. Categories and providers used to be separate
/// sidebar rows; they are now one filter bar above the table.
struct ToolFilter: Hashable, Sendable {
    enum Status: Hashable, Sendable, CaseIterable {
        case all, updates, attention, removable, systemManaged, direct, officialInstaller
    }

    var category: ToolCategory?
    var provider: ProviderID?
    var recency: UsageRecency?
    var status: Status = .all

    static let all = ToolFilter()

    var isFiltered: Bool { self != .all }
}

enum AppRoute: Hashable, Sendable {
    case overview
    case discover
    case tools(ToolFilter)
    case updates
    case issues
    case path
    case cleanup
    /// Environment restore: export, import and templates.
    case restore
    case history
    /// Tools list with this tool selected in the inspector.
    case tool(ToolID)

    /// The sidebar row that should appear selected for this route.
    var sidebarRoute: AppRoute {
        switch self {
        case .tools, .tool: .tools(.all)
        default: self
        }
    }
}

/// Non-domain display settings (Settings ▸ General / Scanning).
struct DisplaySettings: Hashable, Codable, Sendable {
    var launchAtLogin = false
    var notificationsEnabled = true
    var showDependencies = false
    var showUnrecognized = true
    var showSystemManaged = true
    var appearance = AppAppearance.system
    /// Settings › General › Show in menu bar (menu bar extra).
    var showInMenuBar = true

    init() {}

    /// Missing keys keep their defaults, so settings saved by an older version
    /// (or before a field was added) still load.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DisplaySettings()
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? defaults.notificationsEnabled
        showDependencies = try container.decodeIfPresent(Bool.self, forKey: .showDependencies) ?? defaults.showDependencies
        showUnrecognized = try container.decodeIfPresent(Bool.self, forKey: .showUnrecognized) ?? defaults.showUnrecognized
        showSystemManaged = try container.decodeIfPresent(Bool.self, forKey: .showSystemManaged) ?? defaults.showSystemManaged
        appearance = (try? container.decodeIfPresent(AppAppearance.self, forKey: .appearance)) ?? defaults.appearance
        showInMenuBar = (try? container.decodeIfPresent(Bool.self, forKey: .showInMenuBar)) ?? defaults.showInMenuBar
    }

    static let defaultsKey = "DisplaySettings"

    static func load(from defaults: UserDefaults) -> DisplaySettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(DisplaySettings.self, from: data) else { return DisplaySettings() }
        return stored
    }
}

struct ActivityLine: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case command, output, error }

    let id: Int
    let kind: Kind
    let text: String
}

struct ActivityRun: Identifiable, Hashable, Sendable {
    enum State: Hashable {
        case running
        case succeeded(message: String)
        case attention(message: String)
        case failed(message: String)
    }

    let id: UUID
    let plan: OperationPlan
    let title: String
    let startedAt: Date
    var lines: [ActivityLine] = []
    /// Oldest lines dropped to keep memory bounded; see `appendLine(_:)`.
    var omittedLineCount = 0
    var state: State = .running
    var finishedAt: Date?

    var isRunning: Bool { state == .running }
}

struct AppAlert: Identifiable, Hashable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}
