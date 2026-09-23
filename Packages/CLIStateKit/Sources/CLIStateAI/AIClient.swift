import Foundation

/// Language the answer should be written in, from the App's current localization.
public enum AIAnswerLanguage: String, Hashable, Codable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    /// `zh-Hans`, `zh-Hans-CN`, `zh_CN` … → Simplified Chinese; everything else → English.
    public init(localization: String?) {
        let value = (localization ?? "").lowercased().replacingOccurrences(of: "_", with: "-")
        self = value.hasPrefix("zh") && !value.hasPrefix("zh-hant") && !value.contains("-tw") && !value.contains("-hk")
            ? .simplifiedChinese : .english
    }

    /// Name used inside the instructions to the model.
    var promptName: String {
        switch self {
        case .simplifiedChinese: "Simplified Chinese (简体中文)"
        case .english: "English"
        }
    }
}

/// One question for a model: system instructions plus the user message.
public struct AIRequest: Hashable, Sendable {
    public var instructions: String
    public var prompt: String
    public var language: AIAnswerLanguage

    public init(instructions: String, prompt: String, language: AIAnswerLanguage) {
        self.instructions = instructions
        self.prompt = prompt
        self.language = language
    }
}

public protocol AIClient: Sendable {
    /// Text deltas in order. Throws `AIError`; cancelling the consumer cancels the request.
    func streamAnswer(_ request: AIRequest) -> AsyncThrowingStream<String, any Error>
}

extension AIClient {
    /// Collects a short answer, e.g. for "Test Connection".
    public func answer(_ request: AIRequest, limit: Int = 2_000) async throws -> String {
        var text = ""
        for try await delta in streamAnswer(request) {
            text += delta
            if text.count >= limit { break }
        }
        return text
    }
}

extension AIRequest {
    /// Tiny prompt for "Test Connection"; contains nothing about this Mac.
    public static func connectionTest(language: AIAnswerLanguage) -> AIRequest {
        AIRequest(
            instructions: "You are a connectivity check. Reply with a single short word.",
            prompt: "Reply with OK.",
            language: language
        )
    }
}
