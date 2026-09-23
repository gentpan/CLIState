import AppIntents

/// Shortcuts and Siri phrases. Phrases are translated in `AppShortcuts.xcstrings`.
struct CLIStateShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanEnvironmentIntent(),
            phrases: [
                "Scan my development environment with \(.applicationName)",
                "Scan CLI tools with \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Scan Environment", table: "MenuBar"),
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: CheckForUpdatesIntent(),
            phrases: [
                "Check for CLI updates with \(.applicationName)",
                "Which CLI tools can I update in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Check for Updates", table: "MenuBar"),
            systemImageName: "arrow.down.circle"
        )
        AppShortcut(
            intent: WhichCommandIntent(),
            phrases: [
                "Look up a command in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Look Up Command", table: "MenuBar"),
            systemImageName: "text.magnifyingglass"
        )
        AppShortcut(
            intent: OpenToolIntent(),
            phrases: [
                "Open \(\.$tool) in \(.applicationName)",
                "Show a tool in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Open Tool", table: "MenuBar"),
            systemImageName: "hammer"
        )
    }
}
