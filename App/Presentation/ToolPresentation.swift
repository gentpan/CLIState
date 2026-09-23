import CLIStateDomain
import SwiftUI

extension Tool {
    /// The single state shown in lists. Uses only the §8.3 vocabulary.
    var statusKind: StatusKind {
        switch health.status {
        case .pathConflict, .broken, .duplicateInstallation: return .needsAttention
        default: break
        }
        if primaryInstallation?.isSystemManaged == true || primaryInstallation?.ownership.provider == .system { return .systemManaged }
        if hasUpdate { return .updateAvailable }
        if identity.category == .unrecognized { return .unknown }
        guard let primary = primaryInstallation else { return .unknown }
        if primary.isSystemManaged { return .systemManaged }
        switch primary.linkState {
        case .notOnPath: return .notLinked
        case .broken: return .needsAttention
        case .shadowed: return .shadowed
        case .active: return primary.latest != nil ? .latest : .active
        }
    }

    var primaryProvider: ProviderID? { primaryInstallation?.ownership.provider }

    /// Primary command, e.g. `node` for Node.js.
    var command: String {
        resolution?.command ?? primaryInstallation?.executables.first?.name ?? identity.name
    }

    var executableNames: [String] {
        var seen = Set<String>()
        return installations.flatMap(\.executables).map(\.name).filter { seen.insert($0).inserted }
    }

    func matches(search query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        let haystack: [String] = [identity.name, identity.displayName, id.rawValue]
            + executableNames
            + installations.compactMap(\.ownership.packageName)
            + installations.flatMap { [$0.ownership.provider.rawValue, $0.ownership.provider.displayName] }
        return haystack.contains { $0.localizedStandardContains(needle) }
    }

    func installation(_ id: InstallationID) -> ToolInstallation? {
        installations.first { $0.id == id }
    }

    /// The installation that owns an executable path from the resolution chain.
    func installation(forExecutablePath path: String) -> ToolInstallation? {
        installations.first { $0.executables.contains { $0.path == path } }
    }
}

extension ToolInstallation {
    var versionText: String { version?.value.rawValue ?? "—" }

    /// Latest or Update Available; `nil` when no latest version is known.
    var versionStatus: StatusKind? {
        guard latest != nil else { return nil }
        return hasUpdate ? .updateAvailable : .latest
    }

    var hasAnyAction: Bool {
        let caps = capabilities
        return caps.canUpdate || caps.canUninstall || caps.canMoveToTrash || caps.canStart || caps.canStop || caps.canRestart
    }

    var primaryExecutable: ExecutableRef? {
        executables.first { $0.pathPriority != nil } ?? executables.first
    }
}

extension Collection<Tool> {
    /// Display names used by more than one tool in the collection.
    var ambiguousDisplayNames: Set<String> {
        var seen = Set<String>()
        var repeated = Set<String>()
        for tool in self where !seen.insert(tool.identity.displayName).inserted {
            repeated.insert(tool.identity.displayName)
        }
        return repeated
    }
}

/// One row on the Updates screen.
struct UpdateItem: Identifiable, Hashable {
    let tool: Tool
    let installation: ToolInstallation

    var id: InstallationID { installation.id }
    var ref: InstallationRef { InstallationRef(toolID: tool.id, installationID: installation.id) }
    var provider: ProviderID { installation.ownership.provider }
    var latestVersion: String? { installation.latest?.value.rawValue }
}

/// Table row model for Tools, Runtimes, AI CLI and provider screens.
struct ToolRow: Identifiable, Hashable {
    let tool: Tool
    /// Provider shown after the name when another visible tool has the same
    /// display name, e.g. `@opencode-ai/cli · Bun`. Display only; identity is unchanged.
    var providerQualifier: String?

    var id: ToolID { tool.id }
    var name: String { tool.identity.displayName }
    /// `name · Provider` when qualified; used for sorting and accessibility.
    var qualifiedName: String {
        guard let providerQualifier else { return name }
        return "\(name) · \(providerQualifier)"
    }
    var categoryTitle: String { tool.identity.category.title }
    var status: StatusKind { tool.statusKind }
    var statusRank: Int { status.rank }
    var provider: ProviderID? { tool.primaryProvider }
    var providerTitle: String { provider?.displayName ?? "" }
    var version: String { tool.primaryInstallation?.versionText ?? "—" }
    var extraInstallations: Int { max(tool.installations.count - 1, 0) }

    /// Version with numeric-aware ordering.
    var versionSortKey: String { version }
}

extension ToolIdentity {
    /// Registry summaries are localized by id (`tool.summary.<registryID>`);
    /// provider descriptions (e.g. Homebrew `desc`) stay as the provider wrote them.
    var localizedSummary: String? {
        guard let registryID else { return summary }
        let key = "tool.summary.\(registryID)"
        let localized = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        if localized != key { return localized }
        // Registry tools added for environment restore keep their summaries in `Restore.xcstrings`.
        let restore = Bundle.main.localizedString(forKey: key, value: nil, table: "Restore")
        return restore == key ? summary : restore
    }
}
