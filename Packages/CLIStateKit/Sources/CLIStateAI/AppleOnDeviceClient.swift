import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence's on-device foundation model. Nothing leaves the Mac.
public struct AppleOnDeviceClient: AIClient {
    public init() {}

    public static var availability: OnDeviceAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible: return .unavailable(.deviceNotEligible)
                case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceNotEnabled)
                case .modelNotReady: return .unavailable(.modelNotReady)
                @unknown default: return .unavailable(.unknown)
                }
            }
        }
        return .unavailable(.requiresNewerSystem)
        #else
        return .unavailable(.frameworkMissing)
        #endif
    }

    public func streamAnswer(_ request: AIRequest) -> AsyncThrowingStream<String, any Error> {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            return Self.failing(AIError(.onDeviceUnavailable(.requiresNewerSystem)))
        }
        if case let .unavailable(reason) = Self.availability {
            return Self.failing(AIError(.onDeviceUnavailable(reason)))
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: request.instructions)
                    // Snapshots are cumulative; the protocol promises deltas.
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: request.prompt) {
                        try Task.checkCancellation()
                        let current = snapshot.content
                        // Plain-text snapshots only ever grow; anything else is ignored.
                        if current.count > previous.count, current.hasPrefix(previous) {
                            continuation.yield(String(current.dropFirst(previous.count)))
                        }
                        previous = current
                    }
                    if previous.isEmpty { throw AIError(.emptyResponse) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        #else
        return Self.failing(AIError(.onDeviceUnavailable(.frameworkMissing)))
        #endif
    }

    private static func failing(_ error: AIError) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    static func map(_ error: any Error) -> AIError {
        if let error = error as? AIError { return error }
        if error is CancellationError { return AIError(.cancelled) }
        if #available(macOS 27.0, *) {
            if let error = error as? LanguageModelError {
                return switch error {
                case .contextSizeExceeded: AIError(.contextTooLong)
                case .rateLimited: AIError(.rateLimited(retryAfter: nil))
                case .guardrailViolation: AIError(.guardrailViolation)
                case .refusal: AIError(.refusal)
                case .unsupportedLanguageOrLocale: AIError(.unsupportedLanguage)
                case .timeout: AIError(.timedOut)
                default: AIError(.onDeviceFailed)
                }
            }
            if error is SystemLanguageModel.Error { return AIError(.onDeviceUnavailable(.modelNotReady)) }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            return mapLegacy(error)
        }
        return AIError(.onDeviceFailed)
    }

    /// macOS 26 error type (deprecated in 27, still thrown on 26).
    @available(macOS, introduced: 26.0, deprecated: 27.0)
    private static func mapLegacy(_ error: LanguageModelSession.GenerationError) -> AIError {
        switch error {
        case .exceededContextWindowSize: AIError(.contextTooLong)
        case .assetsUnavailable: AIError(.onDeviceUnavailable(.modelNotReady))
        case .guardrailViolation: AIError(.guardrailViolation)
        case .unsupportedLanguageOrLocale: AIError(.unsupportedLanguage)
        case .rateLimited: AIError(.rateLimited(retryAfter: nil))
        case .refusal: AIError(.refusal)
        default: AIError(.onDeviceFailed)
        }
    }
    #endif
}
