import CLIStateDomain
import Foundation

/// `HTTPFetching` over `URLSession`: GET only, HTTPS only, no cookies or cache
/// shared with anything else.
public struct URLSessionHTTPClient: HTTPFetching {
    public enum ClientError: Error, Equatable, Sendable {
        case insecureURL
        case notHTTP
    }

    private let session: URLSession
    private let userAgent: String

    public init(session: URLSession? = nil, userAgent: String = "CLIState") {
        self.session = session ?? Self.makeSession()
        self.userAgent = userAgent
    }

    public func get(_ url: URL, timeout: Duration) async throws -> HTTPResponse {
        guard url.scheme == "https" else { throw ClientError.insecureURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.notHTTP }
        return HTTPResponse(statusCode: http.statusCode, body: data)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}
