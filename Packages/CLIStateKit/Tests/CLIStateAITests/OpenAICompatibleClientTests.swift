import Foundation
import Testing
@testable import CLIStateAI

@Suite("OpenAI-compatible client")
struct OpenAICompatibleClientTests {
    private static let request = AIRequest(instructions: "Be brief.", prompt: "What is node?", language: .english)

    private func client(_ response: FakeURLProtocol.Response, provider: AIProviderKind = .openAICompatible, key: String? = "sk-test-1234567890", model: String = "test-model", temperature: Double? = nil) -> (OpenAICompatibleClient, String) {
        let fake = FakeURLProtocol.register(response)
        let secrets = InMemoryAISecretStore(key.map { [provider: $0] } ?? [:])
        let configuration = AIConfiguration(provider: provider, model: model, customBaseURL: fake.baseURL, temperature: temperature)
        return (OpenAICompatibleClient(configuration: configuration, secrets: secrets, session: fake.session), fake.host)
    }

    private func collect(_ client: OpenAICompatibleClient) async throws -> String {
        var text = ""
        for try await delta in client.streamAnswer(Self.request) { text += delta }
        return text
    }

    private func expectError(_ client: OpenAICompatibleClient, sourceLocation: SourceLocation = #_sourceLocation) async -> AIError? {
        do {
            _ = try await collect(client)
            Issue.record("expected an error", sourceLocation: sourceLocation)
            return nil
        } catch let error as AIError {
            return error
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
            return nil
        }
    }

    private static func sse(_ deltas: [String], done: Bool = true) -> [Data] {
        var events = deltas.map { delta -> String in
            let escaped = String(data: try! JSONEncoder().encode(delta), encoding: .utf8)!
            return "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\(escaped)},\"finish_reason\":null}]}\n\n"
        }
        events.insert("data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}]}\n\n", at: 0)
        if done { events.append("data: [DONE]\n\n") }
        // Split the whole stream at awkward places.
        let bytes = Array(events.joined().utf8)
        return stride(from: 0, to: bytes.count, by: 17).map { Data(bytes[$0..<min($0 + 17, bytes.count)]) }
    }

    // MARK: Request shape

    @Test func sendsChatCompletionRequest() async throws {
        let (client, host) = client(.init(chunks: Self.sse(["Node", ".js ", "是运行时"])), temperature: 0.2)
        let text = try await collect(client)
        #expect(text == "Node.js 是运行时")

        let captured = try #require(FakeURLProtocol.requests(for: host).first)
        #expect(captured.method == "POST")
        #expect(captured.url.absoluteString == "https://\(host)/v1/chat/completions")
        #expect(captured.headers["Authorization"] == "Bearer sk-test-1234567890")
        #expect(captured.headers["Content-Type"] == "application/json")
        #expect(captured.headers["Accept"] == "text/event-stream")

        let body = try #require(captured.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "test-model")
        #expect(json["stream"] as? Bool == true)
        #expect(json["temperature"] as? Double == 0.2)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "Be brief."], ["role": "user", "content": "What is node?"]])
    }

    @Test func omitsTemperatureAndAuthorizationWhenUnset() async throws {
        let (client, host) = client(.init(chunks: Self.sse(["ok"])), key: nil)
        _ = try await collect(client)
        let captured = try #require(FakeURLProtocol.requests(for: host).first)
        #expect(captured.headers["Authorization"] == nil)
        let json = try #require(try JSONSerialization.jsonObject(with: captured.body ?? Data()) as? [String: Any])
        #expect(json["temperature"] == nil)
    }

    @Test func builtInProvidersUseTheirEndpoints() throws {
        let secrets = InMemoryAISecretStore([.openAI: "sk-a", .deepSeek: "sk-b"])
        let openAI = try OpenAICompatibleClient(configuration: AIConfiguration(provider: .openAI), secrets: secrets).makeChatRequest(Self.request)
        #expect(openAI.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(openAI.timeoutInterval == 60)
        let deepSeek = try OpenAICompatibleClient(configuration: AIConfiguration(provider: .deepSeek), secrets: secrets).makeChatRequest(Self.request)
        #expect(deepSeek.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(deepSeek.value(forHTTPHeaderField: "Authorization") == "Bearer sk-b")
    }

    @Test func requiresKeyModelAndValidURL() throws {
        let empty = InMemoryAISecretStore()
        #expect(throws: AIError(.missingAPIKey)) {
            try OpenAICompatibleClient(configuration: AIConfiguration(provider: .openAI), secrets: empty).makeChatRequest(Self.request)
        }
        #expect(throws: AIError(.missingModel)) {
            try OpenAICompatibleClient(configuration: AIConfiguration(provider: .openAICompatible, model: " ", customBaseURL: "http://localhost:11434/v1"), secrets: empty).makeChatRequest(Self.request)
        }
        #expect(throws: AIError(.invalidBaseURL)) {
            try OpenAICompatibleClient(configuration: AIConfiguration(provider: .openAICompatible, model: "llama3", customBaseURL: "localhost:11434"), secrets: empty).makeChatRequest(Self.request)
        }
    }

    // MARK: Streaming edge cases

    @Test func streamWithoutDoneStillFinishes() async throws {
        let (client, _) = client(.init(chunks: Self.sse(["a", "b"], done: false)))
        #expect(try await collect(client) == "ab")
    }

    @Test func stopsAtDone() async throws {
        var chunks = Self.sse(["first"])
        chunks.append(Data("data: {\"choices\":[{\"delta\":{\"content\":\"after done\"}}]}\n\n"))
        let (client, _) = client(.init(chunks: chunks))
        #expect(try await collect(client) == "first")
    }

    @Test func plainJSONAnswerIsAccepted() async throws {
        let body = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"Hello"}}]}"#
        let (client, _) = client(.init(headers: ["Content-Type": "application/json"], chunks: [Data(body)]))
        #expect(try await collect(client) == "Hello")
    }

    @Test func emptyStreamIsAnError() async {
        let (client, _) = client(.init(chunks: [Data("data: [DONE]\n\n")]))
        #expect(await expectError(client)?.kind == .emptyResponse)
    }

    @Test func htmlIsInvalidResponse() async {
        let (client, _) = client(.init(headers: ["Content-Type": "text/html"], chunks: [Data("<html><body>Welcome</body></html>")]))
        #expect(await expectError(client)?.kind == .invalidResponse)
    }

    @Test func errorInsideStreamIsMapped() async {
        let chunks = [Data("data: {\"error\":{\"message\":\"Incorrect API key provided: sk-test-1234567890.\",\"code\":\"invalid_api_key\"}}\n\n")]
        let (client, _) = client(.init(chunks: chunks))
        let error = await expectError(client)
        #expect(error?.kind == .unauthorized)
        #expect(error?.providerMessage?.contains("1234567890") == false)
    }

    @Test func unknownStreamErrorIsProviderError() async {
        let (client, _) = client(.init(chunks: [Data("data: {\"error\":\"model is loading\"}\n\n")]))
        let error = await expectError(client)
        #expect(error?.kind == .providerError)
        #expect(error?.providerMessage == "model is loading")
    }

    // MARK: HTTP and transport errors

    @Test(arguments: [
        (400, AIError.Kind.badRequest),
        (401, .unauthorized),
        (402, .insufficientBalance),
        (403, .forbidden),
        (404, .notFound),
        (500, .serverError(status: 500)),
        (503, .serverError(status: 503)),
        (418, .unexpectedStatus(418)),
    ])
    func mapsHTTPStatus(status: Int, kind: AIError.Kind) async {
        let body = #"{"error":{"message":"nope for sk-test-1234567890","type":"invalid_request_error","code":null}}"#
        let (client, _) = client(.init(status: status, headers: ["Content-Type": "application/json"], chunks: [Data(body)]))
        let error = await expectError(client)
        #expect(error?.kind == kind)
        #expect(error?.providerMessage == "nope for ••••")
    }

    @Test func rateLimitReadsRetryAfter() async {
        let (client, _) = client(.init(status: 429, headers: ["Retry-After": "12"], chunks: [Data(#"{"error":{"message":"slow down","code":"rate_limit_exceeded"}}"#)]))
        #expect(await expectError(client)?.kind == .rateLimited(retryAfter: 12))
    }

    @Test func quotaExhaustionIsNotARateLimit() async {
        let (client, _) = client(.init(status: 429, chunks: [Data(#"{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","code":"insufficient_quota"}}"#)]))
        #expect(await expectError(client)?.kind == .insufficientBalance)
    }

    @Test func unknownModelOn400IsNotFound() async {
        let (client, _) = client(.init(status: 400, chunks: [Data(#"{"error":{"message":"Model Not Exist","type":"invalid_request_error"}}"#)]))
        #expect(await expectError(client)?.kind == .notFound)
    }

    @Test(arguments: [
        (URLError.Code.timedOut, AIError.Kind.timedOut),
        (.notConnectedToInternet, .offline),
        (.cannotFindHost, .cannotConnect),
        (.cannotConnectToHost, .cannotConnect),
        (.serverCertificateUntrusted, .secureConnectionFailed),
    ])
    func mapsURLErrors(code: URLError.Code, kind: AIError.Kind) async {
        let (client, _) = client(.init(error: URLError(code)))
        #expect(await expectError(client)?.kind == kind)
    }

    @Test func cancellingTheConsumerStopsTheStream() async throws {
        let (client, _) = client(.init(chunks: Self.sse((0..<200).map { "token \($0) " })))
        var received = 0
        for try await _ in client.streamAnswer(Self.request) {
            received += 1
            if received == 3 { break }
        }
        #expect(received == 3)
    }

    // MARK: Models

    @Test func listsModels() async throws {
        let body = #"{"object":"list","data":[{"id":"gpt-5-mini"},{"id":"gpt-5"},{"id":"deepseek-chat"}]}"#
        let (client, host) = client(.init(headers: ["Content-Type": "application/json"], chunks: [Data(body)]))
        #expect(try await client.listModels() == ["deepseek-chat", "gpt-5", "gpt-5-mini"])
        let captured = try #require(FakeURLProtocol.requests(for: host).first)
        #expect(captured.method == "GET")
        #expect(captured.url.path() == "/v1/models")
        #expect(captured.headers["Authorization"] == "Bearer sk-test-1234567890")
    }

    @Test func listModelsMapsErrors() async {
        let (client, _) = client(.init(status: 401, chunks: [Data(#"{"error":{"message":"bad key"}}"#)]))
        await #expect(throws: AIError(.unauthorized, providerMessage: "bad key")) { try await client.listModels() }

        let (garbage, _) = self.client(.init(chunks: [Data("not json")]))
        await #expect(throws: AIError(.invalidResponse)) { try await garbage.listModels() }
    }
}

@Suite("AI configuration and secrets")
struct AIConfigurationTests {
    @Test func normalizesCustomBaseURLs() {
        #expect(AIConfiguration.normalizedBaseURL("http://localhost:11434/v1/")?.absoluteString == "http://localhost:11434/v1")
        #expect(AIConfiguration.normalizedBaseURL(" https://openrouter.ai/api/v1/chat/completions ")?.absoluteString == "https://openrouter.ai/api/v1")
        #expect(AIConfiguration.normalizedBaseURL("ftp://example.com") == nil)
        #expect(AIConfiguration.normalizedBaseURL("example.com/v1") == nil)
        #expect(AIConfiguration.normalizedBaseURL("") == nil)
    }

    @Test func knowsWhenDataLeavesTheMac() {
        #expect(!AIConfiguration(provider: .appleOnDevice).sendsDataOffDevice)
        #expect(AIConfiguration(provider: .openAI).sendsDataOffDevice)
        #expect(AIConfiguration(provider: .deepSeek).sendsDataOffDevice)
        #expect(!AIConfiguration(provider: .openAICompatible, customBaseURL: "http://127.0.0.1:1234/v1").sendsDataOffDevice)
        #expect(!AIConfiguration(provider: .openAICompatible, customBaseURL: "http://localhost:11434/v1").sendsDataOffDevice)
        #expect(AIConfiguration(provider: .openAICompatible, customBaseURL: "https://api.moonshot.cn/v1").sendsDataOffDevice)
        #expect(AIConfiguration(provider: .openAICompatible, customBaseURL: "").sendsDataOffDevice)
    }

    @Test func settingsRoundTripWithoutSecrets() throws {
        var settings = AISettings(selectedProvider: .deepSeek)
        settings.configurations[.deepSeek] = AIConfiguration(provider: .deepSeek, model: "deepseek-reasoner")
        settings.configurations[.openAICompatible] = AIConfiguration(provider: .openAICompatible, model: "qwen3", customBaseURL: "http://localhost:11434/v1", temperature: 0.3)
        let data = try JSONEncoder().encode(settings)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.lowercased().contains("key"))
        #expect(json.contains("\"deepSeek\":{"))
        #expect(try JSONDecoder().decode(AISettings.self, from: data) == settings)
        #expect(AISettings().configuration(for: .openAI).model == "gpt-5-mini")
    }

    @Test func answerLanguageFollowsLocalization() {
        #expect(AIAnswerLanguage(localization: "zh-Hans") == .simplifiedChinese)
        #expect(AIAnswerLanguage(localization: "zh_CN") == .simplifiedChinese)
        #expect(AIAnswerLanguage(localization: "zh-Hant") == .english)
        #expect(AIAnswerLanguage(localization: "en") == .english)
        #expect(AIAnswerLanguage(localization: nil) == .english)
    }

    @Test func inMemorySecretStore() throws {
        let store = InMemoryAISecretStore()
        #expect(!store.hasAPIKey(for: .openAI))
        try store.setAPIKey("  sk-abc  ", for: .openAI)
        #expect(try store.apiKey(for: .openAI) == "sk-abc")
        #expect(store.hasAPIKey(for: .openAI))
        #expect(!store.hasAPIKey(for: .deepSeek))
        try store.setAPIKey("", for: .openAI)
        #expect(try store.apiKey(for: .openAI) == nil)
        try store.setAPIKey("sk-def", for: .deepSeek)
        try store.removeAPIKey(for: .deepSeek)
        #expect(!store.hasAPIKey(for: .deepSeek))
    }

    @Test func secretScrubberRemovesKeys() {
        #expect(SecretScrubber.scrub("Incorrect API key provided: sk-proj-abc***xyz9.", knownSecret: nil) == "Incorrect API key provided: sk-••••")
        #expect(SecretScrubber.scrub("token abcdef123 rejected", knownSecret: "abcdef123") == "token •••• rejected")
    }

    @Test func onDeviceAvailabilityIsReported() {
        // Whatever this Mac supports, the call must not crash and must be a known state.
        switch AppleOnDeviceClient.availability {
        case .available, .unavailable: break
        }
    }
}
