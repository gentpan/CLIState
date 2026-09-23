import Foundation

/// Why Apple's on-device model can't answer. The App explains each case.
public enum OnDeviceUnavailableReason: String, Hashable, Codable, Sendable {
    /// Running on macOS earlier than 26.
    case requiresNewerSystem
    /// Built without the FoundationModels SDK.
    case frameworkMissing
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    /// Still downloading or preparing.
    case modelNotReady
    case unknown
}

public enum OnDeviceAvailability: Hashable, Sendable {
    case available
    case unavailable(OnDeviceUnavailableReason)

    public var isAvailable: Bool { self == .available }
}

/// Typed failure without display strings; the App turns `kind` into words and a fix hint.
public struct AIError: Error, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case notConfigured
        case missingAPIKey
        case missingModel
        case invalidBaseURL
        /// HTTP 400: the endpoint rejected the request (often an unsupported parameter).
        case badRequest
        /// HTTP 401: key missing, wrong or revoked.
        case unauthorized
        /// HTTP 403: key valid but not allowed (region, billing, model access).
        case forbidden
        /// HTTP 404: wrong base URL or unknown model.
        case notFound
        /// HTTP 402 or a provider "insufficient balance" error.
        case insufficientBalance
        /// HTTP 429.
        case rateLimited(retryAfter: TimeInterval?)
        /// HTTP 5xx.
        case serverError(status: Int)
        case unexpectedStatus(Int)
        case timedOut
        case offline
        case cannotConnect
        case secureConnectionFailed
        case network(code: Int)
        /// Not a chat-completions stream (HTML page, unknown JSON).
        case invalidResponse
        /// The stream finished without any text.
        case emptyResponse
        /// An error object inside a 200 response or stream.
        case providerError
        case onDeviceUnavailable(OnDeviceUnavailableReason)
        case contextTooLong
        case guardrailViolation
        case refusal
        case unsupportedLanguage
        case onDeviceFailed
        case keychain(status: Int32)
        case cancelled
    }

    public var kind: Kind
    /// Untranslated message from the provider, already scrubbed of API keys.
    public var providerMessage: String?

    public init(_ kind: Kind, providerMessage: String? = nil) {
        self.kind = kind
        self.providerMessage = providerMessage
    }

    /// Maps transport failures, keeping cancellation distinct so the UI stays quiet.
    public static func from(_ error: any Error) -> AIError {
        if let error = error as? AIError { return error }
        if error is CancellationError { return AIError(.cancelled) }
        if let error = error as? URLError { return from(urlError: error) }
        return AIError(.network(code: (error as NSError).code))
    }

    static func from(urlError: URLError) -> AIError {
        switch urlError.code {
        case .cancelled: AIError(.cancelled)
        case .timedOut: AIError(.timedOut)
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            AIError(.offline)
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            AIError(.cannotConnect)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            AIError(.secureConnectionFailed)
        case .badURL, .unsupportedURL:
            AIError(.invalidBaseURL)
        case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData:
            AIError(.invalidResponse)
        default:
            AIError(.network(code: urlError.errorCode))
        }
    }

    /// HTTP status → kind. `code` is the provider's error code string when present.
    static func from(status: Int, code: String?, message: String?, retryAfter: TimeInterval?) -> AIError {
        let lowered = (code ?? "").lowercased() + " " + (message ?? "").lowercased()
        let kind: Kind = switch status {
        case 400 where lowered.contains("model") && (lowered.contains("not exist") || lowered.contains("not found")): .notFound
        case 400: .badRequest
        case 401: .unauthorized
        case 402: .insufficientBalance
        case 403: .forbidden
        case 404: .notFound
        case 408: .timedOut
        case 429 where lowered.contains("insufficient_quota") || lowered.contains("balance"): .insufficientBalance
        case 429: .rateLimited(retryAfter: retryAfter)
        case 500...599: .serverError(status: status)
        default: .unexpectedStatus(status)
        }
        return AIError(kind, providerMessage: message)
    }
}
