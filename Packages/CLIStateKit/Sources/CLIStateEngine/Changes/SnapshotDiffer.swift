import CLIStateDomain
import Foundation

/// Compares two snapshots and lists what changed in the environment. Ignores
/// scan noise: latest-version metadata, timestamps, versions a probe failed to
/// read, and data missing only because a provider failed this time.
public struct SnapshotDiffer: Sendable {
    /// More unrecognized executables than this appearing or disappearing at once
    /// (an app adding its helpers to PATH) are collapsed into one counted change.
    public var unrecognizedCollapseThreshold: Int
    /// How many example names a collapsed change keeps.
    public var collapsedNameLimit: Int

    public init(unrecognizedCollapseThreshold: Int = 5, collapsedNameLimit: Int = 5) {
        self.unrecognizedCollapseThreshold = unrecognizedCollapseThreshold
        self.collapsedNameLimit = collapsedNameLimit
    }

    public func changes(from previous: EnvironmentSnapshot, to current: EnvironmentSnapshot) -> [EnvironmentChange] {
        // A provider that failed keeps stale data or none at all; neither means packages changed.
        let failedBefore = Set(previous.providers.filter { $0.lastError != nil }.map(\.providerID))
        let failedNow = Set(current.providers.filter { $0.lastError != nil }.map(\.providerID))

        var changes: [EnvironmentChange] = []
        changes += toolChanges(previous: previous, current: current, failedBefore: failedBefore, failedNow: failedNow)
        changes += pathChanges(previous: previous, current: current)
        changes += serviceChanges(previous: previous, current: current)
        return changes
    }

    // MARK: Tools

    private func toolChanges(previous: EnvironmentSnapshot, current: EnvironmentSnapshot, failedBefore: Set<ProviderID>, failedNow: Set<ProviderID>) -> [EnvironmentChange] {
        let before = Dictionary(previous.tools.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(current.tools.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var changes: [EnvironmentChange] = []
        var unrecognizedAdded: [Tool] = []
        var unrecognizedRemoved: [Tool] = []

        for tool in current.tools where before[tool.id] == nil {
            guard !Self.onlyOwnedBy(tool, failedBefore) else { continue }
            if tool.identity.category == .unrecognized { unrecognizedAdded.append(tool) } else { changes.append(Self.toolChange(.toolAdded, tool)) }
        }
        for tool in previous.tools where after[tool.id] == nil {
            guard !Self.onlyOwnedBy(tool, failedNow) else { continue }
            if tool.identity.category == .unrecognized { unrecognizedRemoved.append(tool) } else { changes.append(Self.toolChange(.toolRemoved, tool)) }
        }
        changes += collapse(unrecognizedAdded, kind: .toolAdded, collapsed: .unrecognizedToolsAdded)
        changes += collapse(unrecognizedRemoved, kind: .toolRemoved, collapsed: .unrecognizedToolsRemoved)

        for tool in current.tools {
            guard let old = before[tool.id] else { continue }
            changes += installationChanges(old: old, new: tool, failedNow: failedNow)
        }
        return changes.sorted { ($0.toolID?.rawValue ?? "", $0.kind.rawValue, $0.id) < ($1.toolID?.rawValue ?? "", $1.kind.rawValue, $1.id) }
    }

    private func installationChanges(old: Tool, new: Tool, failedNow: Set<ProviderID>) -> [EnvironmentChange] {
        let before = Dictionary(old.installations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.installations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let removed = old.installations.filter { after[$0.id] == nil && !failedNow.contains($0.ownership.provider) }
        let added = new.installations.filter { before[$0.id] == nil }

        var changes: [EnvironmentChange] = []
        var replaced: (old: InstallationID, new: InstallationID)?
        if removed.count == 1, added.count == 1, let gone = removed.first, let arrived = added.first {
            // One installation swapped for another: a version-managed upgrade
            // (`~/.nvm/versions/node/v22` → `v24`) or a move to another provider.
            replaced = (gone.id, arrived.id)
            if gone.ownership.provider != arrived.ownership.provider {
                changes.append(Self.change(.providerChanged, new, arrived, previousProvider: gone.ownership.provider, from: Self.version(gone), to: Self.version(arrived)))
            } else if let from = Self.version(gone), let to = Self.version(arrived), from != to {
                changes.append(Self.change(.versionChanged, new, arrived, from: from, to: to))
            }
        } else {
            changes += removed.map { Self.change(.installationRemoved, old, $0, from: Self.version($0)) }
            changes += added.map { Self.change(.installationAdded, new, $0, to: Self.version($0)) }
        }

        for installation in new.installations {
            guard let prior = before[installation.id] else { continue }
            if prior.ownership.provider != installation.ownership.provider {
                changes.append(Self.change(.providerChanged, new, installation, previousProvider: prior.ownership.provider, from: Self.version(prior), to: Self.version(installation)))
            } else if let from = Self.version(prior), let to = Self.version(installation), from != to {
                changes.append(Self.change(.versionChanged, new, installation, from: from, to: to))
            }
        }

        if let change = activeChange(old: old, new: new, replaced: replaced) {
            changes.append(change)
        }
        return changes
    }

    /// Which binary Terminal runs for the tool's command.
    private func activeChange(old: Tool, new: Tool, replaced: (old: InstallationID, new: InstallationID)?) -> EnvironmentChange? {
        guard let command = new.resolution?.command, old.resolution?.command == command,
              let from = old.resolution?.chain.first, let to = new.resolution?.chain.first
        else { return nil }
        let oldActive = old.activeInstallationID
        let newActive = new.activeInstallationID
        let pathChanged = from.path != to.path
        let installationChanged = oldActive != nil && newActive != nil && oldActive != newActive
        guard pathChanged || installationChanged else { return nil }
        // Already described by the swap above.
        if let replaced, replaced.old == oldActive, replaced.new == newActive { return nil }
        let newInstallation = new.activeInstallation
        return EnvironmentChange(
            kind: .activeExecutableChanged,
            toolID: new.id,
            toolName: new.identity.displayName,
            category: new.identity.category,
            installationID: newActive,
            provider: newInstallation?.ownership.provider,
            previousProvider: old.activeInstallation?.ownership.provider,
            from: from.path,
            to: to.path,
            subject: command
        )
    }

    private func collapse(_ tools: [Tool], kind: EnvironmentChangeKind, collapsed: EnvironmentChangeKind) -> [EnvironmentChange] {
        guard tools.count > unrecognizedCollapseThreshold else { return tools.map { Self.toolChange(kind, $0) } }
        let names = tools.map(\.identity.displayName).sorted()
        return [EnvironmentChange(kind: collapsed, category: .unrecognized, subject: "unrecognized", count: tools.count, names: Array(names.prefix(collapsedNameLimit)))]
    }

    private static func onlyOwnedBy(_ tool: Tool, _ providers: Set<ProviderID>) -> Bool {
        !providers.isEmpty && !tool.installations.isEmpty && tool.installations.allSatisfy { providers.contains($0.ownership.provider) }
    }

    private static func toolChange(_ kind: EnvironmentChangeKind, _ tool: Tool) -> EnvironmentChange {
        let installation = tool.primaryInstallation
        let version = installation.flatMap(Self.version)
        return EnvironmentChange(
            kind: kind,
            toolID: tool.id,
            toolName: tool.identity.displayName,
            category: tool.identity.category,
            installationID: installation?.id,
            provider: installation?.ownership.provider,
            from: kind == .toolRemoved ? version : nil,
            to: kind == .toolAdded ? version : nil,
            subject: tool.resolution?.command
        )
    }

    private static func change(_ kind: EnvironmentChangeKind, _ tool: Tool, _ installation: ToolInstallation, previousProvider: ProviderID? = nil, from: String? = nil, to: String? = nil) -> EnvironmentChange {
        EnvironmentChange(
            kind: kind,
            toolID: tool.id,
            toolName: tool.identity.displayName,
            category: tool.identity.category,
            installationID: installation.id,
            provider: installation.ownership.provider,
            previousProvider: previousProvider,
            from: from,
            to: to,
            subject: tool.resolution?.command
        )
    }

    /// `nil` when unknown: a probe that timed out is not a version change.
    private static func version(_ installation: ToolInstallation) -> String? {
        installation.version?.value.rawValue
    }

    // MARK: PATH

    private func pathChanges(previous: EnvironmentSnapshot, current: EnvironmentSnapshot) -> [EnvironmentChange] {
        // A login shell that failed falls back to a minimal PATH; that isn't the user's change.
        guard previous.shell.source == current.shell.source else { return [] }
        let before = Self.orderedPath(previous.pathEntries)
        let after = Self.orderedPath(current.pathEntries)
        let beforePriority = Dictionary(before.map { ($0.path, $0.priority) }, uniquingKeysWith: { first, _ in first })
        let afterPriority = Dictionary(after.map { ($0.path, $0.priority) }, uniquingKeysWith: { first, _ in first })

        var changes: [EnvironmentChange] = []
        for entry in after where beforePriority[entry.path] == nil {
            changes.append(EnvironmentChange(kind: .pathEntryAdded, to: String(entry.priority), subject: entry.path))
        }
        for entry in before where afterPriority[entry.path] == nil {
            changes.append(EnvironmentChange(kind: .pathEntryRemoved, from: String(entry.priority), subject: entry.path))
        }
        // Entries outside the longest common order moved relative to the rest.
        let commonBefore = before.map(\.path).filter { afterPriority[$0] != nil }
        let commonAfter = after.map(\.path).filter { beforePriority[$0] != nil }
        let stable = Set(Self.longestCommonSubsequence(commonBefore, commonAfter))
        for path in commonAfter where !stable.contains(path) {
            changes.append(EnvironmentChange(kind: .pathEntryMoved, from: beforePriority[path].map(String.init), to: afterPriority[path].map(String.init), subject: path))
        }
        return changes
    }

    /// First occurrence of each directory, in priority order.
    private static func orderedPath(_ entries: [PATHEntry]) -> [(path: String, priority: Int)] {
        var seen = Set<String>()
        return entries.sorted { $0.priority < $1.priority }.compactMap { entry in
            let path = entry.normalizedPath.isEmpty ? entry.rawValue : entry.normalizedPath
            guard entry.status != .duplicate, seen.insert(path).inserted else { return nil }
            return (path, entry.priority)
        }
    }

    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [String] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result.append(a[i])
                i += 1
                j += 1
            // On ties keep the old order's entry, so an entry moved to the front is the one reported.
            } else if table[i + 1][j] > table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    // MARK: Services

    private func serviceChanges(previous: EnvironmentSnapshot, current: EnvironmentSnapshot) -> [EnvironmentChange] {
        let before = Dictionary(previous.services.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tools = Dictionary(current.tools.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return current.services.compactMap { service in
            guard let prior = before[service.id], prior.status != .unknown, service.status != .unknown else { return nil }
            let wasRunning = prior.status == .running
            let isRunning = service.status == .running
            guard wasRunning != isRunning else { return nil }
            let tool = service.toolID.flatMap { tools[$0] }
            return EnvironmentChange(
                kind: isRunning ? .serviceStarted : .serviceStopped,
                toolID: service.toolID,
                toolName: tool?.identity.displayName,
                category: tool?.identity.category,
                installationID: service.installationID,
                provider: service.providerID,
                from: prior.status.rawValue,
                to: service.status.rawValue,
                subject: service.name
            )
        }
    }
}
