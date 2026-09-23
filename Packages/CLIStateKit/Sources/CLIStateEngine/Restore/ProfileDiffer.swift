import CLIStateDomain
import Foundation

/// Compares a profile or template with the current snapshot (Lane N import flow).
/// Read-only; the result only says what *could* be installed.
public struct ProfileDiffer: Sendable {
    let registry: ToolRegistry
    let isValidName: @Sendable (String) -> Bool

    public init(registry: ToolRegistry = .standard, isValidName: @escaping @Sendable (String) -> Bool) {
        self.registry = registry
        self.isValidName = isValidName
    }

    public func diff(_ profile: EnvironmentProfile, snapshot: EnvironmentSnapshot) -> ProfileDiff {
        var statuses: [String: ProfileItemStatus] = [:]
        var candidates: [ProfileItem] = []

        for item in profile.items {
            guard let providerID = item.provider.providerID, item.provider.packageKind != nil else {
                statuses[item.id] = .unavailable(.unsupportedProvider(item.provider.rawValue))
                continue
            }
            guard isInstallableName(item) else {
                statuses[item.id] = .unavailable(.invalidPackageName)
                continue
            }
            if let (installation, version) = installed(item, provider: providerID, in: snapshot) {
                if let expected = item.version, let version, !Self.satisfies(installed: version, expected: expected) {
                    statuses[item.id] = .versionDiffers(installed: version, expected: expected, provider: installation.ownership.provider)
                } else {
                    statuses[item.id] = .installed(version: version, provider: installation.ownership.provider)
                }
                continue
            }
            candidates.append(item)
        }

        let plan = RestorePlanner.stages(for: candidates) { Self.isAvailable($0, in: snapshot) }
        for group in plan.ready {
            for item in group.items { statuses[item.id] = .pending }
        }
        for group in plan.deferred {
            for item in group.items { statuses[item.id] = .pendingAfter(provider: group.provider, enabledBy: group.enabledBy) }
        }
        for group in plan.blocked {
            for item in group.items { statuses[item.id] = .unavailable(.providerMissing(group.provider)) }
        }

        return ProfileDiff(entries: profile.items.compactMap { item in
            statuses[item.id].map { ProfileDiffEntry(item: item, status: $0) }
        })
    }

    static func isAvailable(_ provider: ProviderID, in snapshot: EnvironmentSnapshot) -> Bool {
        snapshot.providers.first { $0.providerID == provider }?.availability.isAvailable ?? false
    }

    private func isInstallableName(_ item: ProfileItem) -> Bool {
        guard isValidName(item.packageName) else { return false }
        guard let tap = item.tap else { return true }
        return item.provider.providerID == .homebrew
            && tap.split(separator: "/", omittingEmptySubsequences: false).count == 2
            && isValidName(tap)
            && !item.packageName.contains("/")
    }

    /// Same provider and package first; otherwise the same registry tool installed
    /// some other way the user controls (Node.js via nvm, Claude Code's native
    /// installer), so a restore never adds a second, competing copy.
    private func installed(_ item: ProfileItem, provider: ProviderID, in snapshot: EnvironmentSnapshot) -> (ToolInstallation, String?)? {
        let wanted = provider == .homebrew ? PathUtil.lastComponent(item.qualifiedName) : item.packageName
        let all = snapshot.tools.flatMap { tool in tool.installations.map { (tool, $0) } }
        if let exact = all.first(where: { _, installation in
            installation.ownership.provider == provider && installation.ownership.packageName == wanted && !installation.isSystemManaged
        }) {
            return (exact.1, exact.1.version?.value.rawValue)
        }
        guard let toolID = item.toolID, let tool = snapshot.tool(toolID) else { return nil }
        let owned = tool.installations.filter { installation in
            !installation.isSystemManaged
                && installation.ownership.confidence >= .probable
                && ![ProviderID.system, .standalone].contains(installation.ownership.provider)
        }
        guard let chosen = owned.first(where: { $0.id == tool.activeInstallationID }) ?? owned.first else { return nil }
        return (chosen, chosen.version?.value.rawValue)
    }

    /// Same or newer counts as installed; unparseable versions only match exactly.
    static func satisfies(installed: String, expected: String) -> Bool {
        if installed == expected { return true }
        guard let current = SemanticVersion(parsing: installed), let wanted = SemanticVersion(parsing: expected) else { return false }
        return !(current < wanted)
    }
}

/// Orders installs by provider and works out which package managers an earlier
/// step will make available.
public enum RestorePlanner {
    /// Package manager → registry tools whose installation provides it.
    public static let bootstrap: [ProviderID: [ToolID]] = [
        .npm: ["node"],
        .pnpm: ["pnpm"],
        .uv: ["uv"],
        .pipx: ["pipx"],
        .cargo: ["rust"],
    ]

    public static func stages(for items: [ProfileItem], isAvailable: (ProviderID) -> Bool) -> RestoreStagePlan {
        var groups: [ProviderID: [ProfileItem]] = [:]
        for item in items {
            guard let provider = item.provider.providerID, RestoreCatalog.installOrder.contains(provider) else { continue }
            groups[provider, default: []].append(item)
        }

        var plan = RestoreStagePlan()
        var waiting: [ProviderID] = []
        var provided = Set<ToolID>()
        for provider in RestoreCatalog.installOrder {
            guard let members = groups[provider], !members.isEmpty else { continue }
            if isAvailable(provider) {
                plan.ready.append(RestoreProviderGroup(provider: provider, items: members))
                provided.formUnion(members.compactMap(\.toolID))
            } else {
                waiting.append(provider)
            }
        }

        // npm can wait for Node.js from Homebrew, pnpm for pnpm from npm, and so on.
        var deferred: [ProviderID: [ToolID]] = [:]
        var changed = true
        while changed {
            changed = false
            for provider in waiting where deferred[provider] == nil {
                let enablers = (bootstrap[provider] ?? []).filter(provided.contains)
                guard !enablers.isEmpty else { continue }
                deferred[provider] = enablers
                provided.formUnion((groups[provider] ?? []).compactMap(\.toolID))
                changed = true
            }
        }
        for provider in waiting {
            let members = groups[provider] ?? []
            if let enablers = deferred[provider] {
                plan.deferred.append(RestoreProviderGroup(provider: provider, items: members, enabledBy: enablers))
            } else {
                plan.blocked.append(RestoreProviderGroup(provider: provider, items: members))
            }
        }
        return plan
    }
}
