import Foundation

/// OpenAI, DeepSeek and any OpenAI-compatible `/chat/completions` endpoint.
public struct OpenAICompatibleClient: AIClient {
    public static let requestTimeout: TimeInterval = 60
    /// Error bodies are read up to this size; enough for any JSON error.
    static let maxErrorBodyBytes = 64 * 1024

    public let configuration: AIConfiguration
    private let secrets: any AISecretStore
    private let session: URLSession

    /// `session` is injectable so tests can route requests through a fake `URLProtocol`.
    public init(configuration: AIConfiguration, secrets: any AISecretStore, session: URLSession = OpenAICompatibleClient.makeSession()) {
        self.configuration = configuration
        self.secrets = secrets
        self.session = session
    }

    /// Ephemeral: no cookies, cache or credential storage.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }

    // MARK: Chat

    public func streamAnswer(_ request: AIRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeChatRequest(request)
                    try await stream(urlRequest, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: scrubbed(AIError.from(error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(_ urlRequest: URLRequest, into continuation: AsyncThrowingStream<String, any Error>.Continuation) async throws {
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AIError(.invalidResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let body = try await collect(bytes, limit: Self.maxErrorBodyBytes)
            throw Self.error(status: http.statusCode, body: body, headers: http)
        }

        var parser = ServerSentEventParser()
        var line = Data()
        // Kept only while nothing parsed as SSE, for servers that answer with plain JSON.
        var rawBody = Data()
        var sawEvent = false
        var producedText = false

        func handle(_ payloads: [String]) throws -> Bool {
            for payload in payloads {
                sawEvent = true
                switch try ChatStreamDecoder.decode(payload) {
                case let .delta(text):
                    producedText = true
                    continuation.yield(text)
                case .empty:
                    continue
                case .done:
                    if !producedText { throw AIError(.emptyResponse) }
                    return true
                case let .error(code, message):
                    throw AIError.from(status: Self.statusHint(code: code), code: code, message: message, retryAfter: nil)
                        .withKind(fallback: .providerError)
                }
            }
            return false
        }

        for try await byte in bytes {
            line.append(byte)
            guard byte == 0x0A else { continue }
            if !sawEvent, rawBody.count < Self.maxErrorBodyBytes { rawBody.append(line) }
            if try handle(parser.feed(line)) { return }
            line.removeAll(keepingCapacity: true)
        }
        if !line.isEmpty {
            if !sawEvent, rawBody.count < Self.maxErrorBodyBytes { rawBody.append(line) }
            if try handle(parser.feed(line)) { return }
        }
        if try handle(parser.finish()) { return }
        if !sawEvent, !rawBody.isEmpty {
            // No `data:` lines at all: a bare JSON document.
            try handlePlainBody(rawBody, continuation: continuation)
            return
        }
        if !producedText { throw AIError(.emptyResponse) }
    }

    private func handlePlainBody(_ body: Data, continuation: AsyncThrowingStream<String, any Error>.Continuation) throws {
        if let envelope = try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: body), let error = envelope.error {
            throw AIError(.providerError, providerMessage: error.message ?? envelope.message)
        }
        if let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: body) {
            let text = (chunk.choices ?? []).compactMap { $0.message?.content ?? $0.delta?.content }.joined()
            if !text.isEmpty {
                continuation.yield(text)
                return
            }
            if chunk.choices != nil { throw AIError(.emptyResponse) }
        }
        throw AIError(.invalidResponse)
    }

    func makeChatRequest(_ request: AIRequest) throws -> URLRequest {
        let model = configuration.trimmedModel
        guard !model.isEmpty else { throw AIError(.missingModel) }
        var urlRequest = try authorizedRequest(path: "chat/completions")
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body = ChatCompletionBody(
            model: model,
            messages: [
                .init(role: "system", content: request.instructions),
                .init(role: "user", content: request.prompt),
            ],
            stream: true,
            temperature: configuration.temperature
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        urlRequest.httpBody = try encoder.encode(body)
        return urlRequest
    }

    // MARK: Models

    /// `GET {base}/models`, sorted ids.
    public func listModels() async throws -> [String] {
        do {
            var urlRequest = try authorizedRequest(path: "models")
            urlRequest.httpMethod = "GET"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw AIError(.invalidResponse) }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.error(status: http.statusCode, body: data.prefix(Self.maxErrorBodyBytes), headers: http)
            }
            guard let list = try? JSONDecoder().decode(ModelListResponse.self, from: data), list.data != nil else {
                throw AIError(.invalidResponse)
            }
            return list.identifiers
        } catch {
            throw scrubbed(AIError.from(error))
        }
    }

    // MARK: Helpers

    private func authorizedRequest(path: String) throws -> URLRequest {
        guard configuration.provider.usesHTTP else { throw AIError(.notConfigured) }
        guard let base = configuration.baseURL else { throw AIError(.invalidBaseURL) }
        var urlRequest = URLRequest(url: base.appending(path: path), timeoutInterval: Self.requestTimeout)
        let key = try apiKey()
        if let key {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else if configuration.provider.requiresAPIKey {
            throw AIError(.missingAPIKey)
        }
        return urlRequest
    }

    private func apiKey() throws -> String? {
        let key = try secrets.apiKey(for: configuration.provider)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    private func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }

    static func error(status: Int, body: Data, headers: HTTPURLResponse) -> AIError {
        let envelope = try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: body)
        let retryAfter = (headers.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
        return AIError.from(status: status, code: envelope?.error?.code, message: envelope?.error?.message ?? envelope?.message, retryAfter: retryAfter)
    }

    /// In-stream errors carry no HTTP status; infer one from well-known codes.
    static func statusHint(code: String?) -> Int {
        switch code?.lowercased() {
        case "invalid_api_key", "authentication_error", "401": 401
        case "insufficient_quota", "insufficient_balance", "402": 402
        case "rate_limit_exceeded", "429": 429
        case "model_not_found", "404": 404
        case "server_error", "500", "503": 500
        default: 0
        }
    }

    /// Providers sometimes echo (part of) the key in error messages.
    private func scrubbed(_ error: AIError) -> AIError {
        guard let message = error.providerMessage else { return error }
        var scrubbedError = error
        scrubbedError.providerMessage = SecretScrubber.scrub(message, knownSecret: (try? apiKey()) ?? nil)
        return scrubbedError
    }
}

extension AIError {
    /// Keeps a specific kind, replacing only the catch-all for unknown statuses.
    func withKind(fallback: Kind) -> AIError {
        guard case .unexpectedStatus = kind else { return self }
        return AIError(fallback, providerMessage: providerMessage)
    }
}

enum SecretScrubber {
    private static let keyPattern = try? NSRegularExpression(pattern: "(sk|pk|rk)-[A-Za-z0-9_\\-\\*\\.]{6,}")

    static func scrub(_ text: String, knownSecret: String?) -> String {
        var output = text
        if let knownSecret, knownSecret.count >= 4 {
            output = output.replacingOccurrences(of: knownSecret, with: "••••")
        }
        if let keyPattern {
            output = keyPattern.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "$1-••••")
        }
        return output
    }
}

struct ChatCompletionBody: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }

    var model: String
    var messages: [Message]
    var stream: Bool
    var temperature: Double?

    private enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(temperature, forKey: .temperature)
    }
}
