import CLIStateDomain
import Foundation

/// Builds the "Export Diagnostics" bundle (§171). Everything is redacted
/// before it is written (§172): the home directory becomes `~`, the account
/// name becomes `<user>`, and no environment variables, command output or shell
/// history are included.
public struct DiagnosticsExporter: Sendable {
    public struct Context: Sendable {
        public var appVersion: String
        public var build: String
        public var osVersion: String
        public var architecture: String
        public var homeDirectory: String
        public var userName: String

        public init(appVersion: String, build: String, osVersion: String, architecture: String, homeDirectory: String, userName: String) {
            self.appVersion = appVersion
            self.build = build
            self.osVersion = osVersion
            self.architecture = architecture
            self.homeDirectory = homeDirectory
            self.userName = userName
        }

        public static func current(appVersion: String, build: String) -> Context {
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            return Context(
                appVersion: appVersion,
                build: build,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: architecture,
                homeDirectory: NSHomeDirectory(),
                userName: NSUserName()
            )
        }
    }

    private let context: Context

    public init(context: Context) {
        self.context = context
    }

    /// File name → contents, already redacted.
    public func files(snapshot: EnvironmentSnapshot?, history: [CommandHistoryEntry], now: Date = Date()) throws -> [String: Data] {
        var files: [String: Data] = [:]
        files["app-version.txt"] = text("""
        CLIState \(context.appVersion) (\(context.build))
        exported \(ISO8601DateFormatter().string(from: now))
        """)

        var system = """
        macOS \(context.osVersion)
        architecture \(context.architecture)
        """
        if let snapshot {
            let shell = snapshot.shell
            system += """

            shell \(shell.shell.executable) (\(shell.source.rawValue))\(shell.failureReason.map { " — \($0)" } ?? "")
            snapshot \(snapshot.depth.rawValue) at \(ISO8601DateFormatter().string(from: snapshot.capturedAt)), schema \(snapshot.schemaVersion)
            tools \(snapshot.tools.count), issues \(snapshot.issues.count), health \(snapshot.health.rawValue)
            PATH entries \(snapshot.pathEntries.count), broken links \(snapshot.brokenSymlinks.count)
            """
        }
        files["system.txt"] = text(system)

        if let snapshot {
            files["path.json"] = try json(snapshot.pathEntries)
            files["providers.json"] = try json(snapshot.providers)
            files["health.json"] = try json(snapshot.issues)
            files["tools.json"] = try json(snapshot.tools.map(ToolSummary.init))
            files["cleanup.json"] = try json(snapshot.cleanupCandidates.map(CleanupSummary.init))
        }
        files["recent-operations.json"] = try json(history.prefix(50).map(OperationSummary.init))
        return files
    }

    /// Writes the files into `directory` (created if needed) and returns the file URLs.
    @discardableResult
    public func write(snapshot: EnvironmentSnapshot?, history: [CommandHistoryEntry], to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try files(snapshot: snapshot, history: history).sorted { $0.key < $1.key }.map { name, data in
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    /// Packs a directory written by `write` into a zip with `/usr/bin/ditto`.
    public static func zip(directory: URL, to archive: URL, runner: any CommandRunning) async throws {
        try? FileManager.default.removeItem(at: archive)
        let command = Command(executable: "/usr/bin/ditto", arguments: ["-c", "-k", "--keepParent", directory.path, archive.path], timeout: .seconds(30))
        let result = try await runner.run(command, environment: ExecutionEnvironment(variables: [:]))
        guard result.succeeded else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: result.stderrString])
        }
    }

    // MARK: Redaction

    func redact(_ string: String) -> String {
        var output = string
        let home = context.homeDirectory
        if !home.isEmpty, home != "/" {
            output = output.replacingOccurrences(of: home, with: "~")
        }
        let user = context.userName
        guard !user.isEmpty else { return output }
        // The account name on its own, e.g. a service's `user` field or `/Users/<name>`
        // outside the home prefix. Whole-token only, so package names that merely
        // contain the name survive.
        let escaped = NSRegularExpression.escapedPattern(for: user)
        guard let expression = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9._-])\(escaped)(?![A-Za-z0-9._-])") else { return output }
        return expression.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "<user>")
    }

    private func text(_ string: String) -> Data {
        Data(redact(string + "\n").utf8)
    }

    private func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let raw = String(decoding: try encoder.encode(value), as: UTF8.self)
        return Data((redact(raw) + "\n").utf8)
    }
}

// MARK: - Summaries

/// What support needs to understand attribution, without the full snapshot.
private struct ToolSummary: Encodable {
    struct Installation: Encodable {
        var id: String
        var provider: String
        var confidence: String
        var linkState: String
        var version: String?
        var latest: String?
        var systemManaged: Bool
        var executables: [String]
        var evidence: [String]
    }

    var id: String
    var name: String
    var category: String
    var health: String
    var activeInstallation: String?
    var resolution: [String]
    var installations: [Installation]

    init(_ tool: Tool) {
        id = tool.id.rawValue
        name = tool.identity.displayName
        category = tool.identity.category.rawValue
        health = tool.health.status.rawValue
        activeInstallation = tool.activeInstallationID?.rawValue
        resolution = tool.resolution?.chain.map { "#\($0.pathPriority.map(String.init) ?? "?") \($0.path)" } ?? []
        installations = tool.installations.map { installation in
            Installation(
                id: installation.id.rawValue,
                provider: installation.ownership.provider.rawValue,
                confidence: installation.ownership.confidence.rawValue,
                linkState: installation.linkState.rawValue,
                version: installation.version?.value.rawValue,
                latest: installation.latest?.value.rawValue,
                systemManaged: installation.isSystemManaged,
                executables: installation.executables.map(\.path),
                evidence: installation.ownership.evidence.map { "\($0)" }
            )
        }
    }
}

private struct CleanupSummary: Encodable {
    var id: String
    var kind: String
    var risk: String
    var reclaimableBytes: Int64?
    var itemCount: Int
    var commands: [String]

    init(_ candidate: CleanupCandidate) {
        id = candidate.id
        kind = candidate.kind.rawValue
        risk = candidate.risk.rawValue
        reclaimableBytes = candidate.reclaimableBytes
        itemCount = max(candidate.items.count, candidate.paths.count)
        commands = candidate.plan?.steps.map(\.displayString) ?? []
    }
}

/// Commands and outcomes only; command output is never stored (§147).
private struct OperationSummary: Encodable {
    var startedAt: Date
    var finishedAt: Date?
    var kind: String
    var trigger: String
    var provider: String
    var status: String
    var exitCode: Int32?
    var commands: [String]
    var targets: [String]

    init(_ entry: CommandHistoryEntry) {
        startedAt = entry.startedAt
        finishedAt = entry.finishedAt
        kind = "\(entry.planKind)"
        trigger = entry.trigger.rawValue
        provider = entry.providerID.rawValue
        status = entry.status.rawValue
        exitCode = entry.exitCode
        commands = entry.commands
        targets = entry.targets.map { target in
            [target.displayName, target.fromVersion, target.toVersion].compactMap { $0 }.joined(separator: " ")
        }
    }
}
