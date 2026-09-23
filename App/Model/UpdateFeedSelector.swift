import Foundation
import Sparkle

/// Where CLI State downloads its own updates from.
enum AppUpdateSource: String, CaseIterable, Sendable {
    /// The update server first, GitHub when the server can't be reached.
    case automatic
    case server
    case github

    static let defaultsKey = "AppUpdateSource"

    var title: String {
        switch self {
        case .automatic: String(localized: "updateSource.automatic", defaultValue: "Automatic", comment: "Update source picker: server first, then GitHub")
        case .server: String(localized: "Update server")
        case .github: String(localized: "GitHub")
        }
    }
}

/// Picks the appcast for each Sparkle check. Some users can't reach GitHub, so a
/// build can list an own update server (`CLIStateUpdateServerFeedURL`) next to the
/// GitHub feed (`SUFeedURL`). Each appcast points at archives on its own host, so
/// switching the feed also switches where the update is downloaded from.
final class UpdateFeedSelector: NSObject, SPUUpdaterDelegate, @unchecked Sendable {
    let serverFeed: URL?
    let githubFeed: URL?

    private let lock = NSLock()
    private var preferServer = true
    private let defaults: UserDefaults
    private let session: URLSession

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        serverFeed = Self.httpsURL(bundle.object(forInfoDictionaryKey: "CLIStateUpdateServerFeedURL"))
        githubFeed = Self.httpsURL(bundle.object(forInfoDictionaryKey: "SUFeedURL"))
        self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.probeTimeout
        configuration.timeoutIntervalForResource = Self.probeTimeout
        session = URLSession(configuration: configuration)
    }

    /// A reachable server answers well within this; slower counts as unreachable.
    static let probeTimeout: TimeInterval = 5

    var hasServer: Bool { serverFeed != nil }

    var source: AppUpdateSource {
        get { defaults.string(forKey: AppUpdateSource.defaultsKey).flatMap(AppUpdateSource.init) ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: AppUpdateSource.defaultsKey) }
    }

    /// The feed the next check uses.
    var currentFeed: URL? {
        switch source {
        case .server: return serverFeed ?? githubFeed
        case .github: return githubFeed ?? serverFeed
        case .automatic:
            let preferServer = lock.withLock { self.preferServer }
            return (preferServer ? serverFeed : nil) ?? githubFeed ?? serverFeed
        }
    }

    /// In automatic mode, checks whether the update server answers and falls back
    /// to GitHub for the following checks if it doesn't. Read-only HEAD request.
    func probe() async {
        guard source == .automatic, let serverFeed else { return }
        var request = URLRequest(url: serverFeed)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let reachable: Bool
        if let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse {
            reachable = (200..<400).contains(http.statusCode)
        } else {
            reachable = false
        }
        lock.withLock { preferServer = reachable }
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        currentFeed?.absoluteString
    }

    /// The appcast or the archive couldn't be downloaded from the server: use GitHub
    /// until the next successful probe.
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let error = error as NSError
        guard source == .automatic, error.domain == SUSparkleErrorDomain,
              error.code == Int(SUError.appcastError.rawValue) || error.code == Int(SUError.downloadError.rawValue),
              currentFeed == serverFeed
        else { return }
        lock.withLock { preferServer = false }
    }

    private static func httpsURL(_ value: Any?) -> URL? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespaces), !string.isEmpty,
              let url = URL(string: string), url.scheme == "https" else { return nil }
        return url
    }
}
