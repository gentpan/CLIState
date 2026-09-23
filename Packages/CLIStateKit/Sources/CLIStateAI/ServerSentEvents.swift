import Foundation

/// Incremental `text/event-stream` parser for chat-completion streams.
/// Feed arbitrary byte chunks; complete `data:` payloads come out.
struct ServerSentEventParser {
    private var buffer = Data()
    private var dataLines: [String] = []

    /// Payloads completed by this chunk, in order.
    mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var payloads: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newline]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            buffer.removeSubrange(buffer.startIndex...newline)
            payloads += consume(line: String(decoding: lineData, as: UTF8.self))
        }
        return payloads
    }

    /// Flushes a final event that wasn't followed by a blank line.
    mutating func finish() -> [String] {
        var payloads: [String] = []
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            buffer.removeAll()
            payloads += consume(line: line)
        }
        if let pending = dispatch() { payloads.append(pending) }
        return payloads
    }

    private mutating func consume(line: String) -> [String] {
        if line.isEmpty {
            return dispatch().map { [$0] } ?? []
        }
        if line.hasPrefix(":") { return [] }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        guard field == "data" else { return [] }
        var completed: [String] = []
        // Some OpenAI-compatible servers omit the blank line between events.
        // A pending payload that is already a whole JSON value (or `[DONE]`) is an event of its own.
        if !dataLines.isEmpty, Self.isComplete(dataLines.joined(separator: "\n")), let pending = dispatch() {
            completed.append(pending)
        }
        dataLines.append(String(value))
        return completed
    }

    private mutating func dispatch() -> String? {
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll()
        return payload
    }

    private static func isComplete(_ payload: String) -> Bool {
        let trimmed = payload.trimmingCharacters(in: .whitespaces)
        if trimmed == "[DONE]" { return true }
        guard trimmed.hasPrefix("{") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
    }
}

/// One decoded stream payload.
enum ChatStreamEvent: Equatable {
    case delta(String)
    /// Chunk without visible text (role header, reasoning, usage).
    case empty
    case done
    case error(code: String?, message: String?)
}

enum ChatStreamDecoder {
    static func decode(_ payload: String) throws -> ChatStreamEvent {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" { return .done }
        guard let data = trimmed.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data)
        else { throw AIError(.invalidResponse) }
        if let error = chunk.error {
            return .error(code: error.code, message: error.message)
        }
        let text = (chunk.choices ?? []).compactMap { $0.delta?.content ?? $0.message?.content }.joined()
        return text.isEmpty ? .empty : .delta(text)
    }
}

// MARK: - DTOs (tolerant: every field optional)

struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var content: String?
        }
        var delta: Delta?
        /// Non-streaming servers that ignore `stream: true`.
        var message: Delta?
    }
    var choices: [Choice]?
    var error: ProviderErrorBody?
}

/// `{"error": {"message": …, "code": …, "type": …}}` (OpenAI, DeepSeek) or
/// `{"error": "…"}` (Ollama and some proxies).
struct ProviderErrorBody: Decodable {
    var message: String?
    var code: String?

    init(from decoder: any Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            message = text
            code = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        if let text = try? container.decodeIfPresent(String.self, forKey: .code) {
            code = text
        } else if let number = try? container.decodeIfPresent(Int.self, forKey: .code) {
            code = String(number)
        } else {
            code = try? container.decodeIfPresent(String.self, forKey: .type)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case message, code, type
    }
}

struct ProviderErrorEnvelope: Decodable {
    var error: ProviderErrorBody?
    /// Some gateways use a top-level `message`.
    var message: String?
}

struct ModelListResponse: Decodable {
    struct Model: Decodable {
        var id: String?
    }
    var data: [Model]?

    var identifiers: [String] {
        let ids = (data ?? []).compactMap(\.id).filter { !$0.isEmpty }
        return Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
