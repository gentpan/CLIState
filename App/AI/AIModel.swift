import AppKit
import CLIStateAI
import CLIStateDomain
import Observation
import SwiftUI

/// What an explanation window is about. Codable so it can be a `WindowGroup` value.
enum AIExplanationTarget: Hashable, Codable {
    case tool(ToolID)
    /// `HealthIssue.id`.
    case issue(String)
}

/// App-wide AI state: Settings › AI, Keychain status and consent. Secrets are
/// never kept here — only whether one exists.
@Observable
@MainActor
final class AIModel {
    private(set) var settings: AISettings
    private(set) var onDeviceAvailability: OnDeviceAvailability
    /// Providers with a key in the Keychain.
    private(set) var providersWithKeys: Set<AIProviderKind> = []

    let secrets: any AISecretStore
    private let defaults: UserDefaults
    private static let settingsKey = "AISettings"
    private static let consentKeyPrefix = "AIConsentSkipped."

    init(secrets: any AISecretStore = KeychainAISecretStore(), defaults: UserDefaults = .standard) {
        self.secrets = secrets
        self.defaults = defaults
        let availability = AppleOnDeviceClient.availability
        onDeviceAvailability = availability
        if let data = defaults.data(forKey: Self.settingsKey),
           let stored = try? JSONDecoder().decode(AISettings.self, from: data) {
            settings = stored
        } else {
            // Nothing chosen yet: use Apple's on-device model when this Mac has it.
            settings = AISettings(selectedProvider: availability.isAvailable ? .appleOnDevice : nil)
        }
        #if DEBUG
        // `-CLIStateAIProvider openAICompatible -CLIStateAIBaseURL … -CLIStateAIModel …`
        // (screenshots, QA); in memory only until the user changes a setting.
        if let raw = defaults.string(forKey: "CLIStateAIProvider") {
            let provider = AIProviderKind(rawValue: raw)
            settings.selectedProvider = provider
            if let provider {
                var configuration = settings.configuration(for: provider)
                if let url = defaults.string(forKey: "CLIStateAIBaseURL") { configuration.customBaseURL = url }
                if let model = defaults.string(forKey: "CLIStateAIModel") { configuration.model = model }
                settings.configurations[provider] = configuration
            }
        }
        #endif
        refreshKeychainStatus()
    }

    // MARK: Settings

    var selectedConfiguration: AIConfiguration? { settings.selectedConfiguration }

    func update(_ change: (inout AISettings) -> Void) {
        change(&settings)
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    func updateConfiguration(for provider: AIProviderKind, _ change: (inout AIConfiguration) -> Void) {
        update { settings in
            var configuration = settings.configuration(for: provider)
            change(&configuration)
            settings.configurations[provider] = configuration
        }
    }

    func refreshAvailability() {
        onDeviceAvailability = AppleOnDeviceClient.availability
    }

    /// Why the selected provider can't be used yet, or `nil` when it's ready.
    func setupProblem(for configuration: AIConfiguration?) -> AIError.Kind? {
        guard let configuration else { return .notConfigured }
        switch configuration.provider {
        case .appleOnDevice:
            if case let .unavailable(reason) = onDeviceAvailability { return .onDeviceUnavailable(reason) }
            return nil
        case .openAI, .deepSeek, .openAICompatible:
            if configuration.baseURL == nil { return .invalidBaseURL }
            if configuration.provider.requiresAPIKey, !providersWithKeys.contains(configuration.provider) { return .missingAPIKey }
            if configuration.trimmedModel.isEmpty { return .missingModel }
            return nil
        }
    }

    // MARK: Keychain

    func hasAPIKey(_ provider: AIProviderKind) -> Bool { providersWithKeys.contains(provider) }

    func saveAPIKey(_ key: String, for provider: AIProviderKind) throws {
        try secrets.setAPIKey(key, for: provider)
        refreshKeychainStatus()
    }

    func removeAPIKey(for provider: AIProviderKind) throws {
        try secrets.removeAPIKey(for: provider)
        refreshKeychainStatus()
    }

    private func refreshKeychainStatus() {
        providersWithKeys = Set(AIProviderKind.allCases.filter { $0.usesHTTP && secrets.hasAPIKey(for: $0) })
    }

    // MARK: Consent

    /// Cloud providers ask before sending, until the user turns that off per provider.
    func needsConsent(for configuration: AIConfiguration) -> Bool {
        configuration.sendsDataOffDevice && !defaults.bool(forKey: Self.consentKeyPrefix + configuration.provider.rawValue)
    }

    func asksBeforeSending(_ provider: AIProviderKind) -> Bool {
        !defaults.bool(forKey: Self.consentKeyPrefix + provider.rawValue)
    }

    func setAsksBeforeSending(_ asks: Bool, for provider: AIProviderKind) {
        defaults.set(!asks, forKey: Self.consentKeyPrefix + provider.rawValue)
    }

    // MARK: Requests

    var answerLanguage: AIAnswerLanguage {
        AIAnswerLanguage(localization: Bundle.main.preferredLocalizations.first)
    }

    func promptBuilder(homeDirectory: String) -> AIPromptBuilder {
        AIPromptBuilder(homeDirectory: homeDirectory, userName: NSUserName(), language: answerLanguage, vocabulary: promptVocabulary)
    }

    /// Answer headings and status words in the UI language, so answers read like the app.
    private var promptVocabulary: AIPromptVocabulary {
        AIPromptVocabulary(
            whatItIs: String(localized: "What it is", table: "AI"),
            whatItsUsedFor: String(localized: "What it's used for", table: "AI"),
            whatsInstalled: String(localized: "What's installed on this Mac", table: "AI"),
            canIRemoveIt: String(localized: "Can I remove it?", table: "AI"),
            nextSteps: String(localized: "Next steps", table: "AI"),
            whatsGoingOn: String(localized: "What's going on", table: "AI"),
            whyItMatters: String(localized: "Why it matters", table: "AI"),
            howToFixIt: String(localized: "How to fix it", table: "AI"),
            terms: answerLanguage == .english ? [:] : [
                "active": StatusKind.active.title,
                "shadowed": StatusKind.shadowed.title,
                "not on PATH": StatusKind.notLinked.title,
            ]
        )
    }

    func makeClient(for configuration: AIConfiguration) -> any AIClient {
        switch configuration.provider {
        case .appleOnDevice: AppleOnDeviceClient()
        case .openAI, .deepSeek, .openAICompatible: OpenAICompatibleClient(configuration: configuration, secrets: secrets)
        }
    }

    /// Opens Settings on the AI pane.
    func openSettings(_ openSettings: OpenSettingsAction) {
        defaults.set("ai", forKey: "SettingsPane")
        openSettings()
        NSApp.activate()
    }
}
