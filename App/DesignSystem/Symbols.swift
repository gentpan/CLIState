import CLIStateDomain

/// SF Symbol names used across the app, in one place so they stay consistent.
enum Symbol {
    // Navigation
    static let overview = "square.grid.2x2"
    static let tools = "hammer"
    static let runtimes = "cube"
    static let aiCLI = "sparkles"
    static let updates = "arrow.down.circle"
    static let issues = "exclamationmark.triangle"
    static let path = "list.number"
    static let cleanup = "archivebox"
    static let history = "clock.arrow.circlepath"
    static let settings = "gearshape"

    // Status
    static let latest = "checkmark.circle.fill"
    static let updateAvailable = "arrow.up.circle.fill"
    static let active = "bolt.circle.fill"
    static let shadowed = "eye.slash"
    static let notLinked = "link"
    static let running = "play.circle.fill"
    static let stopped = "stop.circle"
    static let needsAttention = "exclamationmark.triangle.fill"
    static let systemManaged = "lock.fill"
    static let unknown = "questionmark.circle"
    static let failed = "xmark.octagon.fill"
    static let info = "info.circle.fill"
    static let cancelled = "minus.circle"
    static let good = "checkmark.seal.fill"

    // Actions
    static let refresh = "arrow.clockwise"
    static let update = "arrow.up.circle"
    static let uninstall = "trash"
    static let trash = "trash"
    static let start = "play.fill"
    static let stop = "stop.fill"
    static let restart = "arrow.triangle.2.circlepath"
    static let skip = "forward"
    static let reveal = "folder"
    static let copy = "doc.on.doc"
    static let chevronUp = "chevron.up"
    static let chevronDown = "chevron.down"
    static let chevronRight = "chevron.right"
    static let filter = "line.3.horizontal.decrease.circle"
    static let filterActive = "line.3.horizontal.decrease.circle.fill"
    static let arrowRight = "arrow.right"
    static let resolvesTo = "arrow.turn.down.right"
    static let search = "magnifyingglass"
    static let terminal = "terminal"
    static let automatic = "wand.and.stars"
    static let bell = "bell"
    static let evidence = "checkmark.shield"
    static let config = "doc.text"
    static let service = "server.rack"
    static let link = "link"
    static let lookup = "text.magnifyingglass"

    // Categories
    static func category(_ category: ToolCategory) -> String {
        switch category {
        case .runtime: runtimes
        case .aiCLI: aiCLI
        case .developerTool: "wrench.and.screwdriver"
        case .database: "cylinder.split.1x2"
        case .packageManager: "shippingbox"
        case .dependency: "puzzlepiece"
        case .unrecognized: unknown
        }
    }

    // Providers
    static func provider(_ provider: ProviderID) -> String {
        switch provider {
        case .homebrew: "mug"
        case .npm, .pnpm, .bun: "shippingbox"
        case .uv, .pipx: "square.stack.3d.up"
        case .cargo, .rustup, .go: "gearshape.2"
        case .native: "arrow.down.app"
        case .appBundle: "macwindow"
        case .system: "desktopcomputer"
        case .standalone: "doc"
        default:
            ProviderID.versionManagers.contains(provider) ? "square.stack.3d.down.right" : "questionmark.square"
        }
    }

    /// Every symbol above, for the debug self-check.
    static var all: [String] {
        [overview, tools, runtimes, aiCLI, updates, issues, path, cleanup, history, settings,
         latest, updateAvailable, active, shadowed, notLinked, running, stopped, needsAttention, systemManaged,
         unknown, failed, info, cancelled, good, refresh, update, uninstall, trash, start, stop, restart, skip,
         reveal, copy, chevronUp, chevronDown, chevronRight, filter, filterActive, arrowRight, resolvesTo, search, terminal, automatic, bell,
         evidence, config, service, link, lookup]
            + ToolCategory.allCases.map(category)
            + [ProviderID.homebrew, .npm, .uv, .cargo, .native, .appBundle, .system, .standalone, .nvm, "other"].map(provider)
    }
}
