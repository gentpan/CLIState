import Foundation
@testable import CLIStateAI

/// Routes requests for one unique host to a canned response, so tests never touch the network.
final class FakeURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        /// Delivered as separate `didLoad` calls to exercise partial chunks.
        var chunks: [Data] = []
        var error: URLError?
    }

    struct Captured: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Response] = [:]
    nonisolated(unsafe) private static var captured: [String: [Captured]] = [:]

    /// A fresh host plus a session that only knows the fake protocol.
    static func register(_ response: Response) -> (baseURL: String, session: URLSession, host: String) {
        let host = "fake-\(UUID().uuidString.lowercased()).test"
        lock.withLock { responses[host] = response }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeURLProtocol.self]
        return ("https://\(host)/v1", URLSession(configuration: configuration), host)
    }

    static func requests(for host: String) -> [Captured] {
        lock.withLock { captured[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return lock.withLock { responses[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
              let response = Self.lock.withLock({ Self.responses[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let capture = Captured(method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        Self.lock.withLock { Self.captured[host, default: []].append(capture) }

        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension Data {
    init(_ string: String) { self = Data(string.utf8) }
}
