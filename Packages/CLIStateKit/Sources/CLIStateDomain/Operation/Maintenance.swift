import Foundation

// MARK: - Cleanup

public enum CleanupKind: String, Codable, Sendable, CaseIterable {
    /// Download caches: `brew cleanup`, `npm cache clean`, `uv cache prune`.
    case providerCache
    /// Old kegs / versions kept after upgrades.
    case oldVersions
    /// Dependencies nothing needs any more: `brew autoremove`.
    case orphanedDependencies
    /// Dangling links in PATH directories.
    case brokenSymlink
    /// Inactive runtime installs (e.g. an old nvm Node). Suggestion only in 1.0.
    case unusedRuntime
    /// Files a tool left in the home directory (caches, logs, settings), moved to the Trash.
    case leftovers
}

public enum CleanupRisk: String, Codable, Sendable {
    /// Caches and dangling links; regenerated or already useless.
    case low
    /// Removes installed packages (orphaned dependencies, old runtimes).
    case medium
}

/// A previewed cleanup. Built from read-only dry runs (`brew cleanup --dry-run`,
/// `brew autoremove --dry-run`), so what the user confirms is what runs.
public struct CleanupCandidate: Identifiable, Hashable, Codable, Sendable {
    /// Stable: `<kind>:<provider or path>`.
    public var id: String
    public var kind: CleanupKind
    public var providerID: ProviderID?
    public var risk: CleanupRisk
    public var items: [PreflightItem]
    public var paths: [String]
    public var reclaimableBytes: Int64?
    /// `nil` for suggestion-only candidates.
    public var plan: OperationPlan?

    public init(kind: CleanupKind, providerID: ProviderID?, risk: CleanupRisk, items: [PreflightItem] = [], paths: [String] = [], reclaimableBytes: Int64? = nil, plan: OperationPlan?, subject: String? = nil) {
        self.id = "\(kind.rawValue):\(subject ?? providerID?.rawValue ?? paths.first ?? "")"
        self.kind = kind
        self.providerID = providerID
        self.risk = risk
        self.items = items
        self.paths = paths
        self.reclaimableBytes = reclaimableBytes
        self.plan = plan
    }
}

public protocol CleanupProvider: ToolProvider {
    /// Read-only: runs dry-run commands to preview what cleanup would do.
    func cleanupCandidates(context: ProviderContext) async throws -> [CleanupCandidate]
}

// MARK: - Update policy

/// Per-tool choice the user makes (user decision, 2026-09-13): stay manual,
/// get notified, or let CLIState update automatically.
public enum AutoUpdatePolicy: String, Codable, Sendable, CaseIterable {
    /// No background checks surface this tool.
    case off
    /// Default. Check in the background and notify; never install.
    case notify
    /// Install matching updates in the background, then rescan and record history.
    case automatic
}

public enum AutoUpdateScope: String, Codable, Sendable, CaseIterable {
    /// Skip updates whose `UpdateKind` is `.major` or `.unknown`.
    case patchAndMinor
    case all
}

/// How often CLIState refreshes package info and checks for updates in the background.
public enum UpdateCheckInterval: String, Codable, Sendable, CaseIterable {
    case hourly, every3Hours, every6Hours, daily

    public var seconds: TimeInterval {
        switch self {
        case .hourly: 60 * 60
        case .every3Hours: 3 * 60 * 60
        case .every6Hours: 6 * 60 * 60
        case .daily: 24 * 60 * 60
        }
    }
}

public struct UpdatePreferences: Hashable, Codable, Sendable {
    public var defaultPolicy: AutoUpdatePolicy
    public var providerPolicies: [ProviderID: AutoUpdatePolicy]
    public var toolPolicies: [ToolID: AutoUpdatePolicy]
    public var automaticScope: AutoUpdateScope
    /// Versions the user chose to skip, keyed by installation.
    public var skippedVersions: [InstallationID: String]
    /// Local hour (0–23) after which automatic updates are installed, once a day.
    public var checkHour: Int
    public var requiresACPower: Bool
    /// Refresh provider metadata (e.g. `brew update`) before every update check.
    /// Read commands disable Homebrew's auto-update (F1), so without this the
    /// local package data — and therefore "latest" — goes stale.
    public var refreshMetadataBeforeCheck: Bool
    /// Background refresh-and-check cadence while the app runs.
    public var checkInterval: UpdateCheckInterval

    public init(
        defaultPolicy: AutoUpdatePolicy = .notify,
        providerPolicies: [ProviderID: AutoUpdatePolicy] = [:],
        toolPolicies: [ToolID: AutoUpdatePolicy] = [:],
        automaticScope: AutoUpdateScope = .patchAndMinor,
        skippedVersions: [InstallationID: String] = [:],
        checkHour: Int = 10,
        requiresACPower: Bool = true,
        refreshMetadataBeforeCheck: Bool = true,
        checkInterval: UpdateCheckInterval = .every3Hours
    ) {
        self.defaultPolicy = defaultPolicy
        self.providerPolicies = providerPolicies
        self.toolPolicies = toolPolicies
        self.automaticScope = automaticScope
        self.skippedVersions = skippedVersions
        self.checkHour = checkHour
        self.requiresACPower = requiresACPower
        self.refreshMetadataBeforeCheck = refreshMetadataBeforeCheck
        self.checkInterval = checkInterval
    }

    private enum CodingKeys: String, CodingKey {
        case defaultPolicy, providerPolicies, toolPolicies, automaticScope, skippedVersions, checkHour, requiresACPower, refreshMetadataBeforeCheck, checkInterval
    }

    /// Tolerates preferences saved by older or newer versions: a missing or unreadable
    /// key (e.g. a policy this version doesn't know) takes its default, the rest survive.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UpdatePreferences()
        defaultPolicy = (try? container.decodeIfPresent(AutoUpdatePolicy.self, forKey: .defaultPolicy)) ?? defaults.defaultPolicy
        providerPolicies = (try? container.decodeIfPresent([ProviderID: AutoUpdatePolicy].self, forKey: .providerPolicies)) ?? defaults.providerPolicies
        toolPolicies = (try? container.decodeIfPresent([ToolID: AutoUpdatePolicy].self, forKey: .toolPolicies)) ?? defaults.toolPolicies
        automaticScope = (try? container.decodeIfPresent(AutoUpdateScope.self, forKey: .automaticScope)) ?? defaults.automaticScope
        skippedVersions = (try? container.decodeIfPresent([InstallationID: String].self, forKey: .skippedVersions)) ?? defaults.skippedVersions
        checkHour = (try? container.decodeIfPresent(Int.self, forKey: .checkHour)) ?? defaults.checkHour
        requiresACPower = (try? container.decodeIfPresent(Bool.self, forKey: .requiresACPower)) ?? defaults.requiresACPower
        refreshMetadataBeforeCheck = (try? container.decodeIfPresent(Bool.self, forKey: .refreshMetadataBeforeCheck)) ?? defaults.refreshMetadataBeforeCheck
        checkInterval = (try? container.decodeIfPresent(UpdateCheckInterval.self, forKey: .checkInterval)) ?? defaults.checkInterval
    }

    /// Tool setting beats provider setting beats the default.
    public func policy(for tool: ToolID, provider: ProviderID) -> AutoUpdatePolicy {
        toolPolicies[tool] ?? providerPolicies[provider] ?? defaultPolicy
    }

    /// Whether a background run may install this update without asking.
    public func allowsAutomaticInstall(tool: ToolID, installation: ToolInstallation) -> Bool {
        guard policy(for: tool, provider: installation.ownership.provider) == .automatic,
              installation.capabilities.canUpdate,
              installation.ownership.permitsMutation,
              installation.hasUpdate
        else { return false }
        if let latest = installation.latest?.value.rawValue, skippedVersions[installation.id] == latest {
            return false
        }
        switch automaticScope {
        case .all: return true
        case .patchAndMinor: return [.patch, .minor].contains(installation.updateKind)
        }
    }
}

extension UpdatePreferences {
    /// Tool IDs change when a package gains a registry entry (`homebrew.cocoapods` →
    /// `cocoapods`). Moves per-tool policies whose tool is gone to the tool that now
    /// owns the same package; `nil` when nothing moved.
    public func migratingToolIDs(in snapshot: EnvironmentSnapshot) -> UpdatePreferences? {
        let known = Set(snapshot.tools.map(\.id))
        var result = self
        for (id, policy) in toolPolicies where !known.contains(id) {
            let raw = id.rawValue
            guard let dot = raw.firstIndex(of: "."), dot != raw.startIndex else { continue }
            let namespace = String(raw[..<dot])
            let package = String(raw[raw.index(after: dot)...])
            // npm, pnpm and bun packages share the `npm.` namespace.
            let providers: Set<ProviderID> = namespace == ProviderID.npm.rawValue ? [.npm, .pnpm, .bun] : [ProviderID(namespace)]
            guard let owner = snapshot.tools.first(where: { tool in
                tool.installations.contains { providers.contains($0.ownership.provider) && $0.ownership.packageName == package }
            }), result.toolPolicies[owner.id] == nil else { continue }
            result.toolPolicies[id] = nil
            result.toolPolicies[owner.id] = policy
        }
        return result == self ? nil : result
    }
}
