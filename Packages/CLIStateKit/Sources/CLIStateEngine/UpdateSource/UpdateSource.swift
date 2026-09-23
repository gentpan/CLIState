import CLIStateDomain
import Foundation

/// Read-only latest-version lookup for native installations (C4). Only used
/// during deep scans because it touches the network.
public protocol UpdateSource: Sendable {
    func canHandle(_ definition: UpdateSourceDefinition) -> Bool
    func latest(for definition: UpdateSourceDefinition, discovery: DiscoveryResult) async -> UpdateSourceResult?
}

/// `npm view <package> dist-tags --json`, using the npm the user's PATH resolves.
public struct NPMDistTagUpdateSource: UpdateSource {
    private let runner: any CommandRunning
    private let timeout: Duration

    public init(runner: any CommandRunning, timeout: Duration = .seconds(15)) {
        self.runner = runner
        self.timeout = timeout
    }

    public func canHandle(_ definition: UpdateSourceDefinition) -> Bool {
        if case .npmDistTags = definition { return true }
        return false
    }

    public func latest(for definition: UpdateSourceDefinition, discovery: DiscoveryResult) async -> UpdateSourceResult? {
        guard case let .npmDistTags(package, channel) = definition,
              !package.hasPrefix("-"),
              let npm = discovery.binaries.candidates(named: "npm").first?.path
        else { return nil }
        let command = Command(
            executable: npm,
            arguments: ["view", package, "dist-tags", "--json"],
            environmentOverrides: ["NO_UPDATE_NOTIFIER": "1", "npm_config_update_notifier": "false", "NO_COLOR": "1"],
            timeout: timeout
        )
        guard let result = try? await runner.run(command, environment: discovery.session.execution), result.succeeded else { return nil }
        return Self.parse(result.stdout, package: package, channel: channel)
    }

    static func sourceID(package: String) -> String { "npm:\(package)" }

    static func parse(_ data: Data, package: String, channel: String) -> UpdateSourceResult? {
        // npm ≤ 10 prints an object; npm 11+ wraps the same object in an array.
        let json = try? JSONSerialization.jsonObject(with: data)
        guard let object = (json as? [String: Any]) ?? (json as? [[String: Any]])?.last else { return nil }
        let channels = object.compactMapValues { $0 as? String }
        guard let latest = channels[channel] else { return nil }
        return UpdateSourceResult(sourceID: sourceID(package: package), channel: channel, latestVersion: latest, channels: channels)
    }
}
