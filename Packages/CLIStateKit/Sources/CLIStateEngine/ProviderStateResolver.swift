import CLIStateDomain
import Foundation

/// Decides which inventories feed the merge and how each provider is reported.
/// A provider that failed this scan keeps its previous packages, rebuilt from the
/// previous snapshot and marked `.stale` (§219, §220).
struct ProviderStateResolver: Sendable {
    struct Resolved: Sendable {
        var inventories: [ProviderInventory]
        var snapshots: [ProviderSnapshot]
    }

    func resolve(inventories: [ProviderInventory], failedProviders: [ProviderID: String], previous: EnvironmentSnapshot?, depth: ScanDepth) -> Resolved {
        let previousProviders = Dictionary((previous?.providers ?? []).map { ($0.providerID, $0) }, uniquingKeysWith: { first, _ in first })
        var effective = inventories
        var snapshots: [ProviderSnapshot] = []

        for inventory in inventories {
            let prior = previousProviders[inventory.providerID]
            snapshots.append(ProviderSnapshot(
                providerID: inventory.providerID,
                availability: inventory.availability,
                instance: inventory.instance,
                layout: inventory.layout,
                freshness: inventory.availability.isAvailable ? .fresh(inventory.scannedAt) : .unavailable,
                toolCount: inventory.tools.count,
                serviceCount: inventory.services.count,
                latestCheckedAt: depth == .deep && inventory.depth == .deep ? inventory.scannedAt : prior?.latestCheckedAt,
                lastError: failedProviders[inventory.providerID],
                warnings: inventory.warnings,
                metadataUpdatedAt: inventory.metadataUpdatedAt ?? prior?.metadataUpdatedAt
            ))
        }

        let scanned = Set(inventories.map(\.providerID))
        for (provider, reason) in failedProviders.sorted(by: { $0.key < $1.key }) where !scanned.contains(provider) {
            let prior = previousProviders[provider]
            if let previous, let stale = staleInventory(provider: provider, previous: previous, prior: prior) {
                effective.append(stale)
                snapshots.append(ProviderSnapshot(
                    providerID: provider,
                    availability: stale.availability,
                    instance: stale.instance,
                    layout: stale.layout,
                    freshness: .stale(stale.scannedAt),
                    toolCount: stale.tools.count,
                    serviceCount: stale.services.count,
                    latestCheckedAt: prior?.latestCheckedAt,
                    lastError: reason,
                    warnings: prior?.warnings ?? [],
                    metadataUpdatedAt: prior?.metadataUpdatedAt
                ))
            } else {
                snapshots.append(ProviderSnapshot(
                    providerID: provider,
                    availability: prior?.availability ?? .unavailable(provider, reason: reason),
                    instance: prior?.instance,
                    layout: prior?.layout ?? ProviderLayout(),
                    freshness: .unavailable,
                    lastError: reason
                ))
            }
        }
        return Resolved(inventories: effective, snapshots: snapshots.sorted { $0.providerID < $1.providerID })
    }

    /// Rebuilds a provider inventory from the installations it contributed last time.
    private func staleInventory(provider: ProviderID, previous: EnvironmentSnapshot, prior: ProviderSnapshot?) -> ProviderInventory? {
        var tools: [ProviderTool] = []
        for tool in previous.tools {
            for installation in tool.installations where installation.ownership.provider == provider {
                guard let package = installation.ownership.packageName,
                      installation.ownership.evidence.contains(.inventoryContains(provider: provider, package: package))
                else { continue }
                let version = installation.version?.value.rawValue
                let isRegistryTool = tool.identity.registryID != nil
                tools.append(ProviderTool(
                    providerID: provider,
                    instanceID: installation.ownership.instance,
                    packageName: package,
                    kind: Self.kind(provider: provider, installPrefix: installation.installPrefix),
                    displayName: isRegistryTool ? nil : tool.identity.displayName,
                    summary: isRegistryTool ? nil : tool.identity.summary,
                    homepage: isRegistryTool ? nil : tool.identity.homepage?.absoluteString,
                    installedVersions: version.map { [$0] } ?? [],
                    activeVersion: version,
                    latestVersion: installation.latest?.value.rawValue,
                    isPinned: Self.wasPinned(installation),
                    installPrefix: installation.installPrefix,
                    executableNames: installation.executables.map(\.name).uniqued(),
                    executablePaths: installation.executables.map(\.path),
                    isDirect: installation.isDirect,
                    dependencies: installation.dependencies,
                    installedAt: installation.installedAt
                ))
            }
        }
        let services = previous.services.filter { $0.providerID == provider }.map {
            ProviderService(providerID: provider, name: $0.name, status: $0.status, rawStatus: $0.rawStatus, user: $0.user, plistPath: $0.plistPath, exitCode: $0.exitCode)
        }
        guard prior != nil || !tools.isEmpty else { return nil }

        let staleDate: Date
        switch prior?.freshness {
        case let .fresh(date)?, let .stale(date)?: staleDate = date
        default: staleDate = previous.capturedAt
        }
        return ProviderInventory(
            providerID: provider,
            availability: prior?.availability ?? ProviderAvailability(providerID: provider, isAvailable: true),
            instance: prior?.instance,
            layout: prior?.layout ?? ProviderLayout(),
            tools: tools,
            services: services,
            depth: previous.depth,
            scannedAt: staleDate
        )
    }

    private static func kind(provider: ProviderID, installPrefix: String?) -> PackageKind {
        switch provider {
        case .homebrew: installPrefix?.contains("/Caskroom/") == true ? .cask : .formula
        case .npm, .pnpm, .bun: .globalPackage
        default: .tool
        }
    }

    /// The snapshot keeps no `isPinned`, but for these providers the merge only withholds
    /// update from an uninstallable package because it is pinned.
    private static func wasPinned(_ installation: ToolInstallation) -> Bool {
        [.pipx, .pnpm, .cargo].contains(installation.ownership.provider)
            && installation.capabilities.canUninstall && !installation.capabilities.canUpdate
    }
}
