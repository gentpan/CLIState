import Foundation

/// Where an explanation is generated. The App localizes the names.
public enum AIProviderKind: String, CaseIterable, Codable, Sendable, CodingKeyRepresentable {
    /// Apple Intelligence foundation model, on this Mac (macOS 26+).
    case appleOnDevice
    case openAI
    case deepSeek
    /// Any `/chat/completions` endpoint: Ollama, LM Studio, Kimi, Qwen, OpenRouter …
    case openAICompatible

    /// Built-in endpoint; `nil` when the user must supply one.
    public var defaultBaseURL: URL? {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1")
        case .deepSeek: URL(string: "https://api.deepseek.com")
        case .appleOnDevice, .openAICompatible: nil
        }
    }

    /// Suggested model until the user picks one from "Fetch Models".
    public var defaultModel: String {
        switch self {
        case .appleOnDevice: ""
        case .openAI: "gpt-5-mini"
        case .deepSeek: "deepseek-chat"
        case .openAICompatible: ""
        }
    }

    public var usesHTTP: Bool { self != .appleOnDevice }

    /// Custom endpoints such as a local Ollama may run without a key.
    public var requiresAPIKey: Bool {
        switch self {
        case .openAI, .deepSeek: true
        case .appleOnDevice, .openAICompatible: false
        }
    }

    /// Keychain account name. Stable: changing it orphans stored keys.
    public var secretAccount: String { rawValue }
}

/// Non-secret settings for one provider. API keys live in `AISecretStore` only.
public struct AIConfiguration: Hashable, Codable, Sendable {
    public var provider: AIProviderKind
    public var model: String
    /// User-supplied endpoint; only used by `openAICompatible`.
    public var customBaseURL: String
    /// `nil` sends no temperature, which some models (e.g. reasoning models) require.
    public var temperature: Double?

    public init(provider: AIProviderKind, model: String? = nil, customBaseURL: String = "", temperature: Double? = nil) {
        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.customBaseURL = customBaseURL
        self.temperature = temperature
    }

    /// The endpoint requests go to, or `nil` when a custom URL is missing or invalid.
    public var baseURL: URL? {
        switch provider {
        case .appleOnDevice: return nil
        case .openAI, .deepSeek: return provider.defaultBaseURL
        case .openAICompatible: return Self.normalizedBaseURL(customBaseURL)
        }
    }

    public var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether answers leave this Mac. Loopback endpoints (Ollama, LM Studio) don't.
    public var sendsDataOffDevice: Bool {
        switch provider {
        case .appleOnDevice: return false
        case .openAI, .deepSeek: return true
        case .openAICompatible:
            guard let host = baseURL?.host()?.lowercased() else { return true }
            return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        }
    }

    /// Accepts `https://host/v1`, a trailing slash, or a pasted `…/chat/completions` URL.
    public static func normalizedBaseURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["/chat/completions", "/models"] where text.lowercased().hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil
        else { return nil }
        return components.url
    }
}

/// Everything the Settings › AI pane stores (UserDefaults, no secrets).
public struct AISettings: Hashable, Codable, Sendable {
    /// `nil` means AI explanations are off.
    public var selectedProvider: AIProviderKind?
    public var configurations: [AIProviderKind: AIConfiguration]

    public init(selectedProvider: AIProviderKind? = nil, configurations: [AIProviderKind: AIConfiguration] = [:]) {
        self.selectedProvider = selectedProvider
        self.configurations = configurations
    }

    public func configuration(for provider: AIProviderKind) -> AIConfiguration {
        configurations[provider] ?? AIConfiguration(provider: provider)
    }

    public var selectedConfiguration: AIConfiguration? {
        selectedProvider.map(configuration(for:))
    }
}
