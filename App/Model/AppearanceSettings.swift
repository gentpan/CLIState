import AppKit
import Foundation

/// Settings › General › Appearance. Applied app-wide through `NSApp.appearance`,
/// so every window (main, Settings, sheets, alerts, panels) follows it at once.
enum AppAppearance: String, CaseIterable, Codable, Sendable {
    case system, light, dark

    var title: LocalizedStringResource {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @MainActor
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Settings › General › Language. Stored as this app's own `AppleLanguages`
/// default, which Foundation reads at launch to pick the localization.
enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    private static let key = "AppleLanguages"

    /// The app's own choice only; `UserDefaults.standard` would also return the
    /// system-wide list from the global domain.
    static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard let domain = Bundle.main.bundleIdentifier,
              let languages = defaults.persistentDomain(forName: domain)?[key] as? [String],
              let first = languages.first else { return .system }
        if first.hasPrefix("zh-Hans") || first == "zh" || first == "zh-CN" { return .simplifiedChinese }
        if first == "en" || first.hasPrefix("en-") { return .english }
        return .system
    }

    func store(in defaults: UserDefaults = .standard) {
        switch self {
        case .system: defaults.removeObject(forKey: Self.key)
        case .simplifiedChinese, .english: defaults.set([rawValue], forKey: Self.key)
        }
    }

    /// The localization this choice loads on the next launch.
    var localization: String? {
        switch self {
        case .simplifiedChinese, .english:
            return rawValue
        case .system:
            let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[Self.key] as? [String]
            return Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: global ?? Locale.preferredLanguages).first
        }
    }

    /// True when the running UI uses a different localization than this choice would.
    var needsRestart: Bool {
        localization != Bundle.main.preferredLocalizations.first
    }
}

enum AppRelauncher {
    /// Starts a fresh instance of this app, then quits, so launch-time settings
    /// such as the language take effect. Launch arguments carry over, except a
    /// language override that would mask the new choice.
    @MainActor
    static func relaunch() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = argumentsWithoutLanguageOverride(Array(CommandLine.arguments.dropFirst()))
        _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        NSApp.terminate(nil)
    }

    static func argumentsWithoutLanguageOverride(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            if arguments[index] == "-AppleLanguages" || arguments[index] == "-AppleLocale" {
                index += 2
                continue
            }
            result.append(arguments[index])
            index += 1
        }
        return result
    }
}
