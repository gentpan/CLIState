import CLIStateDomain
import CryptoKit
import Foundation

/// Engine-side cleanup candidates (plan §13). Provider caches and orphaned
/// dependencies come from `CleanupProvider`s; this covers what only the merged
/// view can see: dangling PATH links and inactive version-manager runtimes.
public struct CleanupAdvisor: Sendable {
    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    public func candidates(tools: [Tool], brokenSymlinks: [BrokenSymlink]) -> [CleanupCandidate] {
        (brokenLinkCandidates(brokenSymlinks, tools: tools) + unusedRuntimeCandidates(tools)).sorted { $0.id < $1.id }
    }

    /// One candidate per link so each file is confirmed on its own; moved to the Trash, never `rm` (§159).
    private func brokenLinkCandidates(_ links: [BrokenSymlink], tools: [Tool]) -> [CleanupCandidate] {
        links.compactMap { link in
            let directory = PathUtil.directory(of: link.path)
            guard !AttributionEngine.isSystemLocation(link.path) else { return nil }
            if fileSystem.exists(atPath: directory), !fileSystem.isWritable(atPath: directory) { return nil }

            let owner = tools.lazy.compactMap { tool in
                tool.installations.first { $0.executables.contains { $0.path == link.path } }.map { (tool, $0) }
            }.first
            let name = PathUtil.lastComponent(link.path)
            let provider = owner?.1.ownership.provider
            let subject = link.path
            let plan = OperationPlan(
                id: Self.stableUUID("cleanup:\(CleanupKind.brokenSymlink.rawValue):\(subject)"),
                kind: .cleanup(.brokenSymlink),
                providerID: .standalone,
                targets: [OperationTarget(toolID: owner?.0.id, installationID: owner?.1.id, packageName: name, displayName: owner?.0.identity.displayName ?? name)],
                steps: [.moveToTrash(path: link.path)],
                requiresNetwork: false,
                mutationScope: "trash"
            )
            return CleanupCandidate(
                kind: .brokenSymlink,
                providerID: provider == .standalone ? nil : provider,
                risk: .low,
                items: [PreflightItem(name: link.path, change: .remove)],
                paths: [link.path],
                plan: plan,
                subject: subject
            )
        }
    }

    /// Suggestion only (`plan == nil`): removing a runtime is the version manager's job.
    private func unusedRuntimeCandidates(_ tools: [Tool]) -> [CleanupCandidate] {
        tools.flatMap { tool -> [CleanupCandidate] in
            guard tool.identity.category == .runtime, tool.activeInstallationID != nil else { return [] }
            // A lazy-loading shell function may select any of these at runtime (F4).
            let lazy = tool.resolution?.shadows.contains { $0.kind == .function || $0.kind == .alias } ?? false
            guard !lazy else { return [] }
            return tool.installations.compactMap { installation in
                guard ProviderID.versionManagers.contains(installation.ownership.provider),
                      installation.linkState == .notOnPath
                else { return nil }
                let location = installation.installPrefix ?? installation.executables.first.map { PathUtil.directory(of: $0.path) }
                return CleanupCandidate(
                    kind: .unusedRuntime,
                    providerID: installation.ownership.provider,
                    risk: .medium,
                    items: [PreflightItem(name: tool.identity.displayName, change: .remove, fromVersion: installation.version?.value.rawValue)],
                    paths: location.map { [$0] } ?? [],
                    plan: nil,
                    subject: installation.id.rawValue
                )
            }
        }
    }

    static func stableUUID(_ seed: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(seed.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], (bytes[6] & 0x0f) | 0x50, bytes[7],
                           (bytes[8] & 0x3f) | 0x80, bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
