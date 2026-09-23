import CLIStateDomain
import Foundation

// Read-only questions answered from the latest snapshot, shared by the menu bar
// extra and Shortcuts. Nothing here runs a process or touches the file system.

// MARK: - Command lookup

/// One executable a command name reaches, with the installation that owns it.
public struct CommandCandidate: Hashable, Sendable {
    public var executable: ExecutableRef
    public var toolID: ToolID
    public var toolName: String
    public var installationID: InstallationID
    public var provider: ProviderID
    public var confidence: AttributionConfidence
    public var version: String?

    public init(executable: ExecutableRef, toolID: ToolID, toolName: String, installationID: InstallationID, provider: ProviderID, confidence: AttributionConfidence, version: String?) {
        self.executable = executable
        self.toolID = toolID
        self.toolName = toolName
        self.installationID = installationID
        self.provider = provider
        self.confidence = confidence
        self.version = version
    }
}

/// What the terminal runs for a command name, like `which -a`, from snapshot data.
public struct CommandLookup: Hashable, Sendable {
    public var command: String
    /// Matches reachable through PATH, in priority order; the first one runs.
    public var pathMatches: [CommandCandidate]
    /// Installed executables with this name that PATH doesn't reach.
    public var offPath: [CommandCandidate]
    /// Aliases, functions or builtins that run before any PATH lookup.
    public var shellShadows: [ShellShadow]

    public var active: CommandCandidate? { pathMatches.first }
    public var shadowed: [CommandCandidate] { Array(pathMatches.dropFirst()) }
    public var isFound: Bool { !pathMatches.isEmpty || !offPath.isEmpty }

    public init(command: String, in snapshot: EnvironmentSnapshot) {
        let name = Self.commandName(from: command)
        var pathMatches: [CommandCandidate] = []
        var offPath: [CommandCandidate] = []
        var seen = Set<String>()
        for tool in snapshot.tools {
            for installation in tool.installations {
                for executable in installation.executables where executable.name == name {
                    // The same file can be listed by more than one installation; the first owner wins.
                    guard seen.insert(executable.path).inserted else { continue }
                    let candidate = CommandCandidate(
                        executable: executable,
                        toolID: tool.id,
                        toolName: tool.identity.displayName,
                        installationID: installation.id,
                        provider: installation.ownership.provider,
                        confidence: installation.ownership.confidence,
                        version: installation.version?.value.rawValue
                    )
                    if executable.pathPriority != nil {
                        pathMatches.append(candidate)
                    } else {
                        offPath.append(candidate)
                    }
                }
            }
        }
        pathMatches.sort { ($0.executable.pathPriority ?? .max, $0.executable.path) < ($1.executable.pathPriority ?? .max, $1.executable.path) }
        offPath.sort { $0.executable.path < $1.executable.path }
        self.command = name
        self.pathMatches = pathMatches
        self.offPath = offPath
        self.shellShadows = name.isEmpty ? [] : snapshot.shell.shadows[name] ?? []
    }

    /// Accepts `node`, `which node`, `which -a node` or a path such as `/opt/homebrew/bin/node`.
    public static func commandName(from input: String) -> String {
        var words = input.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first == "which" || words.first == "type" || words.first == "command" {
            words.removeFirst()
            words.removeAll { $0.hasPrefix("-") }
        }
        guard let word = words.first else { return "" }
        return word.contains("/") ? (word as NSString).lastPathComponent : word
    }
}

// MARK: - Tool search

public enum ToolSearch {
    /// Tools matching `query`, best first: exact name or command, then prefix,
    /// then substring, then provider. An empty query returns every tool by name.
    public static func rank(_ tools: [Tool], query: String) -> [Tool] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scored: [(tool: Tool, score: Int)] = tools.compactMap { tool in
            guard let score = needle.isEmpty ? 0 : score(tool, needle) else { return nil }
            return (tool, score)
        }
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            let order = lhs.tool.identity.displayName.localizedStandardCompare(rhs.tool.identity.displayName)
            return order == .orderedSame ? lhs.tool.id < rhs.tool.id : order == .orderedAscending
        }
        .map(\.tool)
    }

    /// Lower is better; `nil` when the tool doesn't match.
    static func score(_ tool: Tool, _ needle: String) -> Int? {
        var names = [tool.identity.displayName, tool.identity.name, tool.id.rawValue]
        names += tool.installations.flatMap(\.executables).map(\.name)
        names += tool.installations.compactMap(\.ownership.packageName)
        if names.contains(where: { $0.compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) { return 0 }
        if names.contains(where: { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }) { return 1 }
        if names.contains(where: { $0.localizedStandardContains(needle) }) { return 2 }
        if tool.installations.contains(where: { $0.ownership.provider.rawValue.localizedStandardContains(needle) }) { return 3 }
        return nil
    }
}

// MARK: - Digest

/// Counts of issues by severity.
public struct IssueSummary: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var severity: HealthSeverity
        public var count: Int
    }

    public var critical: Int
    public var warning: Int
    public var info: Int

    public init(_ issues: [HealthIssue]) {
        critical = issues.count { $0.severity == .critical }
        warning = issues.count { $0.severity == .warning }
        info = issues.count { $0.severity == .info }
    }

    public var total: Int { critical + warning + info }
    public var worst: HealthSeverity? { breakdown.first?.severity }

    /// Severities that occur, most severe first.
    public var breakdown: [Entry] {
        [Entry(severity: .critical, count: critical), Entry(severity: .warning, count: warning), Entry(severity: .info, count: info)]
            .filter { $0.count > 0 }
    }
}

/// Available updates and issues, as the menu bar extra and Shortcuts summarize them.
public struct EnvironmentDigest: Hashable, Sendable {
    public struct Update: Identifiable, Hashable, Sendable {
        public var toolID: ToolID
        public var installationID: InstallationID
        public var name: String
        public var provider: ProviderID
        public var installedVersion: String?
        public var latestVersion: String?
        public var updateKind: UpdateKind
        public var canUpdate: Bool

        public var id: InstallationID { installationID }
    }

    public var toolCount: Int
    /// Sorted by tool name; skipped versions are left out.
    public var updates: [Update]
    public var issues: IssueSummary

    /// `tools` should already be filtered the way the UI shows them.
    public init(tools: [Tool], issues: [HealthIssue], skippedVersions: [InstallationID: String] = [:]) {
        toolCount = tools.count
        updates = tools.flatMap { tool in
            tool.installations.compactMap { installation -> Update? in
                guard installation.hasUpdate else { return nil }
                let latest = installation.latest?.value.rawValue
                if let latest, skippedVersions[installation.id] == latest { return nil }
                return Update(
                    toolID: tool.id,
                    installationID: installation.id,
                    name: tool.identity.displayName,
                    provider: installation.ownership.provider,
                    installedVersion: installation.version?.value.rawValue,
                    latestVersion: latest,
                    updateKind: installation.updateKind,
                    canUpdate: installation.capabilities.canUpdate
                )
            }
        }
        .sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.installationID < rhs.installationID : order == .orderedAscending
        }
        self.issues = IssueSummary(issues)
    }

    /// The first `limit` updates and how many more there are.
    public func topUpdates(limit: Int) -> (shown: [Update], remaining: Int) {
        let shown = Array(updates.prefix(max(limit, 0)))
        return (shown, updates.count - shown.count)
    }

    public var hasUpdatableItems: Bool { updates.contains(where: \.canUpdate) }
}
