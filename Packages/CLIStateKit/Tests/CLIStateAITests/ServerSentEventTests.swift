import Foundation
import Testing
@testable import CLIStateAI

@Suite("Server-sent events")
struct ServerSentEventTests {
    private func parseAll(_ chunks: [String]) -> [String] {
        var parser = ServerSentEventParser()
        var payloads: [String] = []
        for chunk in chunks { payloads += parser.feed(Data(chunk.utf8)) }
        return payloads + parser.finish()
    }

    @Test func splitsEventsOnBlankLines() {
        let payloads = parseAll(["data: {\"a\":1}\n\ndata: {\"a\":2}\n\ndata: [DONE]\n\n"])
        #expect(payloads == ["{\"a\":1}", "{\"a\":2}", "[DONE]"])
    }

    @Test func joinsMultiLineData() {
        let payloads = parseAll(["data: {\"choices\":\ndata: []}\n\n"])
        #expect(payloads == ["{\"choices\":\n[]}"])
    }

    @Test func reassemblesPartialChunks() {
        let stream = "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\r\n\r\ndata: [DONE]\r\n\r\n"
        let bytes = Array(stream.utf8)
        // Split every 3 bytes, cutting through the multi-byte characters and CRLFs.
        var parser = ServerSentEventParser()
        var payloads: [String] = []
        for index in stride(from: 0, to: bytes.count, by: 3) {
            payloads += parser.feed(Data(bytes[index..<Swift.min(index + 3, bytes.count)]))
        }
        payloads += parser.finish()
        #expect(payloads == ["{\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}", "[DONE]"])
    }

    @Test func ignoresCommentsAndOtherFields() {
        let payloads = parseAll([": keep-alive\n\nevent: message\nid: 7\ndata: {\"x\":true}\n\n"])
        #expect(payloads == ["{\"x\":true}"])
    }

    @Test func toleratesMissingBlankLines() {
        let payloads = parseAll(["data: {\"a\":1}\ndata: {\"a\":2}\ndata: [DONE]"])
        #expect(payloads == ["{\"a\":1}", "{\"a\":2}", "[DONE]"])
    }

    @Test func decodesDeltasDoneAndErrors() throws {
        #expect(try ChatStreamDecoder.decode("{\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}") == .delta("Hi"))
        #expect(try ChatStreamDecoder.decode("{\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}") == .empty)
        #expect(try ChatStreamDecoder.decode("{\"choices\":[{\"delta\":{\"reasoning_content\":\"hmm\",\"content\":null}}]}") == .empty)
        #expect(try ChatStreamDecoder.decode("{\"choices\":[],\"usage\":{\"total_tokens\":3}}") == .empty)
        #expect(try ChatStreamDecoder.decode(" [DONE] ") == .done)
        #expect(try ChatStreamDecoder.decode("{\"error\":{\"message\":\"Rate limit\",\"type\":\"requests\",\"code\":\"rate_limit_exceeded\"}}") == .error(code: "rate_limit_exceeded", message: "Rate limit"))
        #expect(try ChatStreamDecoder.decode("{\"error\":\"model not loaded\"}") == .error(code: nil, message: "model not loaded"))
        #expect(throws: AIError.self) { try ChatStreamDecoder.decode("<html>") }
    }

    @Test func parsesModelLists() throws {
        let json = #"{"object":"list","data":[{"id":"gpt-5-mini","object":"model"},{"id":"deepseek-chat"},{"id":"gpt-5-mini"},{"object":"model"},{"id":"a-model","extra":{"nested":1}}]}"#
        let list = try JSONDecoder().decode(ModelListResponse.self, from: Data(json.utf8))
        #expect(list.identifiers == ["a-model", "deepseek-chat", "gpt-5-mini"])
    }
}
