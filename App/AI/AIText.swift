import CLIStateAI
import SwiftUI

// All AI strings live in `AI.xcstrings` (table "AI") so they merge independently
// of `Localizable.xcstrings`.

enum AISymbol {
    static let explain = "sparkles"
    static let onDevice = "desktopcomputer"
    static let cloud = "cloud"
    static let key = "key"
    static let privacy = "hand.raised"
    static let send = "paperplane"
    static let stop = "stop.fill"
    static let regenerate = "arrow.clockwise"
    static let copy = "doc.on.doc"
    static let settings = "gearshape"
    static let models = "list.bullet"
    static let test = "bolt.horizontal"
}

/// AI window and settings sizes, on the 4 pt grid.
enum AILayout {
    static let windowDefaultWidth: CGFloat = 640
    static let windowDefaultHeight: CGFloat = 720
    static let windowMinWidth: CGFloat = 480
    static let windowMinHeight: CGFloat = 400
    static let contentMaxWidth: CGFloat = 720
    static let payloadMaxHeight: CGFloat = 320
    static let bulletWidth: CGFloat = 12
}

extension AIProviderKind {
    /// Picker title.
    var title: String {
        switch self {
        case .appleOnDevice: String(localized: "Apple Intelligence (on this Mac)", table: "AI")
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .openAICompatible: String(localized: "Custom (OpenAI-compatible)", table: "AI")
        }
    }

    /// Short name for labels and sentences.
    var shortName: String {
        switch self {
        case .appleOnDevice: String(localized: "Apple Intelligence", table: "AI")
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .openAICompatible: String(localized: "Custom provider", table: "AI")
        }
    }

    var symbol: String { self == .appleOnDevice ? AISymbol.onDevice : AISymbol.cloud }
}

extension AIConfiguration {
    /// `Apple Intelligence · on this Mac`, `DeepSeek · deepseek-chat`.
    var label: String {
        switch provider {
        case .appleOnDevice: String(localized: "Apple Intelligence · on this Mac", table: "AI")
        default: trimmedModel.isEmpty ? provider.shortName : "\(provider.shortName) · \(trimmedModel)"
        }
    }
}

extension OnDeviceAvailability {
    var title: String {
        switch self {
        case .available: String(localized: "Ready", table: "AI")
        case let .unavailable(reason): reason.title
        }
    }
}

extension OnDeviceUnavailableReason {
    var title: String {
        switch self {
        case .requiresNewerSystem: String(localized: "Requires macOS 26 or later", table: "AI")
        case .frameworkMissing: String(localized: "Not available in this build", table: "AI")
        case .deviceNotEligible: String(localized: "Not supported on this Mac", table: "AI")
        case .appleIntelligenceNotEnabled: String(localized: "Apple Intelligence is turned off", table: "AI")
        case .modelNotReady: String(localized: "Model is still downloading", table: "AI")
        case .unknown: String(localized: "Unavailable", table: "AI")
        }
    }

    var explanation: String {
        switch self {
        case .requiresNewerSystem:
            String(localized: "Apple's on-device model needs macOS 26 or later. You can use OpenAI, DeepSeek or a custom provider instead.", table: "AI")
        case .frameworkMissing:
            String(localized: "This copy of CLI State was built without Apple's on-device model. Use another provider instead.", table: "AI")
        case .deviceNotEligible:
            String(localized: "Apple Intelligence needs a Mac with Apple silicon. You can use OpenAI, DeepSeek or a custom provider instead.", table: "AI")
        case .appleIntelligenceNotEnabled:
            String(localized: "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri, then come back.", table: "AI")
        case .modelNotReady:
            String(localized: "macOS is still downloading or preparing the model. Try again in a few minutes.", table: "AI")
        case .unknown:
            String(localized: "Apple's on-device model isn't available right now.", table: "AI")
        }
    }
}

/// Human words for a failure, plus what to do about it.
struct AIErrorText {
    enum Fix {
        case openSettings
        case retry
        case none
    }

    let message: String
    let hint: String?
    let fix: Fix
}

extension AIError {
    func text(provider: AIProviderKind?) -> AIErrorText {
        let name = provider?.shortName ?? String(localized: "The AI provider", table: "AI")
        switch kind {
        case .notConfigured:
            return AIErrorText(message: String(localized: "AI explanations aren't set up yet.", table: "AI"), hint: String(localized: "Choose a provider in Settings › AI.", table: "AI"), fix: .openSettings)
        case .missingAPIKey:
            return AIErrorText(message: String(localized: "\(name) needs an API key.", table: "AI"), hint: String(localized: "Add the API key in Settings › AI. It's stored in your Keychain.", table: "AI"), fix: .openSettings)
        case .missingModel:
            return AIErrorText(message: String(localized: "No model is selected.", table: "AI"), hint: String(localized: "Enter a model name or use Fetch Models in Settings › AI.", table: "AI"), fix: .openSettings)
        case .invalidBaseURL:
            return AIErrorText(message: String(localized: "The base URL isn't valid.", table: "AI"), hint: String(localized: "Use a full address such as http://localhost:11434/v1 in Settings › AI.", table: "AI"), fix: .openSettings)
        case .badRequest:
            return AIErrorText(message: String(localized: "\(name) rejected the request.", table: "AI"), hint: String(localized: "The model may not support this kind of request. Try another model in Settings › AI.", table: "AI"), fix: .openSettings)
        case .unauthorized:
            return AIErrorText(message: String(localized: "\(name) didn't accept the API key.", table: "AI"), hint: String(localized: "Check the API key in Settings › AI.", table: "AI"), fix: .openSettings)
        case .forbidden:
            return AIErrorText(message: String(localized: "This API key isn't allowed to use the model.", table: "AI"), hint: String(localized: "Check your account's access and region, or choose another model in Settings › AI.", table: "AI"), fix: .openSettings)
        case .notFound:
            return AIErrorText(message: String(localized: "The model or address wasn't found.", table: "AI"), hint: String(localized: "Check the model name and base URL in Settings › AI.", table: "AI"), fix: .openSettings)
        case .insufficientBalance:
            return AIErrorText(message: String(localized: "Your \(name) account is out of credit.", table: "AI"), hint: String(localized: "Add credit on the provider's website, or switch providers in Settings › AI.", table: "AI"), fix: .openSettings)
        case let .rateLimited(retryAfter):
            let hint = retryAfter.map { seconds in
                String(localized: "Try again in \(Int(seconds.rounded(.up))) seconds.", table: "AI")
            } ?? String(localized: "Wait a moment, then try again.", table: "AI")
            return AIErrorText(message: String(localized: "Too many requests to \(name).", table: "AI"), hint: hint, fix: .retry)
        case .serverError:
            return AIErrorText(message: String(localized: "\(name) had a problem answering.", table: "AI"), hint: String(localized: "This is usually temporary. Try again shortly.", table: "AI"), fix: .retry)
        case let .unexpectedStatus(status):
            return AIErrorText(message: String(localized: "\(name) returned an unexpected response (HTTP \(status)).", table: "AI"), hint: nil, fix: .retry)
        case .timedOut:
            return AIErrorText(message: String(localized: "The request timed out.", table: "AI"), hint: String(localized: "Check your connection and try again.", table: "AI"), fix: .retry)
        case .offline:
            return AIErrorText(message: String(localized: "You appear to be offline.", table: "AI"), hint: String(localized: "Connect to the internet, or use Apple Intelligence on this Mac.", table: "AI"), fix: .retry)
        case .cannotConnect:
            return AIErrorText(message: String(localized: "Couldn't connect to \(name).", table: "AI"), hint: String(localized: "Check the base URL in Settings › AI. For a local server, make sure it's running.", table: "AI"), fix: .openSettings)
        case .secureConnectionFailed:
            return AIErrorText(message: String(localized: "A secure connection couldn't be made.", table: "AI"), hint: String(localized: "Check the base URL and your network (proxy or VPN).", table: "AI"), fix: .openSettings)
        case .network:
            return AIErrorText(message: String(localized: "A network error occurred.", table: "AI"), hint: String(localized: "Check your connection and try again.", table: "AI"), fix: .retry)
        case .invalidResponse:
            return AIErrorText(message: String(localized: "The answer couldn't be read.", table: "AI"), hint: String(localized: "Make sure the base URL points to an OpenAI-compatible API (it usually ends in /v1).", table: "AI"), fix: .openSettings)
        case .emptyResponse:
            return AIErrorText(message: String(localized: "The model returned an empty answer.", table: "AI"), hint: String(localized: "Try again, or choose another model.", table: "AI"), fix: .retry)
        case .providerError:
            return AIErrorText(message: String(localized: "\(name) reported an error.", table: "AI"), hint: nil, fix: .retry)
        case let .onDeviceUnavailable(reason):
            return AIErrorText(message: reason.title, hint: reason.explanation, fix: .openSettings)
        case .contextTooLong:
            return AIErrorText(message: String(localized: "There's too much information for the model.", table: "AI"), hint: String(localized: "Try a cloud provider with a larger context window.", table: "AI"), fix: .openSettings)
        case .guardrailViolation, .refusal:
            return AIErrorText(message: String(localized: "The model declined to answer.", table: "AI"), hint: String(localized: "Try again, or use another provider.", table: "AI"), fix: .retry)
        case .unsupportedLanguage:
            return AIErrorText(message: String(localized: "The model doesn't support this language.", table: "AI"), hint: String(localized: "Try another provider, or switch CLI State to English.", table: "AI"), fix: .openSettings)
        case .onDeviceFailed:
            return AIErrorText(message: String(localized: "Apple Intelligence couldn't answer.", table: "AI"), hint: String(localized: "Try again in a moment.", table: "AI"), fix: .retry)
        case let .keychain(status):
            return AIErrorText(message: String(localized: "The Keychain couldn't be used (error \(Int(status))).", table: "AI"), hint: String(localized: "Allow CLI State to access its Keychain item, then try again.", table: "AI"), fix: .openSettings)
        case .cancelled:
            return AIErrorText(message: String(localized: "Stopped.", table: "AI"), hint: nil, fix: .retry)
        }
    }
}
