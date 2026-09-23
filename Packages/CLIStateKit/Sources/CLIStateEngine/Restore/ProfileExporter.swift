import CLIStateDomain
import Foundation

/// Builds an `EnvironmentProfile` from a scan (Lane N, layer 1). Only packages the
/// user installed on purpose with a package manager CLIState can install with:
/// confirmed ownership, not system-managed, not dependency-only. Never paths,
/// environment variables or anything else about the machine.
public struct ProfileExporter: Sendable {
    /// Package managers' own packages: reinstalling them through themselves is noise.
    static let bundledPackages: [ProviderID: Set<String>] = [
        .npm: ["npm", "corepack"],
        .pnpm: ["pnpm"],
    ]

    let isValidName: @Sendable (String) -> Bool

    /// `isValidName` is the provider layer's `PackageNameValidator.isValid`.
    public init(isValidName: @escaping @Sendable (String) -> Bool) {
        self.isValidName = isValidName
    }

    /// `packages` are the providers' inventories from the same scan. They add what
    /// the snapshot doesn't keep (cask vs. formula, tap, pin); without them casks
    /// are recognised by their Caskroom prefix and taps are left out.
    public func profile(from snapshot: EnvironmentSnapshot, packages: [ProviderTool] = [], source: ProfileSource? = nil, name: String? = nil, note: String? = nil, createdAt: Date) -> EnvironmentProfile {
        let byInstallation = Dictionary(packages.map { ($0.installationID, $0) }, uniquingKeysWith: { first, _ in first })
        let caskroom = snapshot.providers.first { $0.providerID == .homebrew }?.layout[.homebrewCaskroom]

        var items: [ProfileItem] = []
        for tool in snapshot.tools where tool.identity.category != .dependency && tool.identity.category != .unrecognized {
            for installation in tool.installations {
                guard let item = item(for: installation, tool: tool, package: byInstallation[installation.id], caskroom: caskroom) else { continue }
                items.append(item)
            }
        }
        items.sort { lhs, rhs in
            let left = RestoreCatalog.installOrder.firstIndex(of: lhs.provider.providerID ?? .standalone) ?? .max
            let right = RestoreCatalog.installOrder.firstIndex(of: rhs.provider.providerID ?? .standalone) ?? .max
            if left != right { return left < right }
            if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
            return lhs.qualifiedName.localizedStandardCompare(rhs.qualifiedName) == .orderedAscending
        }
        return EnvironmentProfile(createdAt: createdAt, name: Self.trimmed(name), note: Self.trimmed(note), source: source, items: items)
    }

    private func item(for installation: ToolInstallation, tool: Tool, package: ProviderTool?, caskroom: String?) -> ProfileItem? {
        let ownership = installation.ownership
        guard ownership.permitsMutation, !installation.isSystemManaged, installation.isDirect != false,
              let packageName = ownership.packageName, isValidName(packageName)
        else { return nil }
        if let package, package.isDirect == false { return nil }
        guard !(Self.bundledPackages[ownership.provider]?.contains(packageName) ?? false) else { return nil }

        let kind: PackageKind
        switch ownership.provider {
        case .homebrew:
            let isCask = package.map { $0.kind == .cask }
                ?? caskroom.map { root in installation.installPrefix?.hasPrefix(root + "/") == true }
                ?? false
            kind = isCask ? .cask : .formula
        case .npm, .pnpm:
            kind = .globalPackage
        default:
            kind = .tool
        }
        guard let provider = ProfileProvider(providerID: ownership.provider, kind: kind) else { return nil }
        // Linked pnpm packages and cargo crates from git or a path can't be reinstalled by name.
        if package?.isPinned == true, [.pnpm, .cargo].contains(ownership.provider) { return nil }

        let tap = package?.tap.flatMap { tap in
            tap.split(separator: "/").count == 2 && isValidName(tap) ? tap : nil
        }
        return ProfileItem(
            toolID: tool.identity.registryID.map(ToolID.init),
            provider: provider,
            packageName: packageName,
            version: installation.version?.value.rawValue,
            pinned: ownership.provider == .homebrew && package?.isPinned == true,
            tap: tap
        )
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// `tap`, `brew` and `cask` lines for `brew bundle`. Nothing else: no `mas`,
/// `vscode` or shell commands, and every value is quoted.
public enum BrewfileWriter {
    public static func brewfile(for profile: EnvironmentProfile, isValidName: (String) -> Bool) -> String {
        let homebrew = profile.items.filter { $0.provider == .homebrewFormula || $0.provider == .homebrewCask }
            .filter { isValidName($0.qualifiedName) }
        let taps = homebrew.compactMap(\.tap).filter { $0.split(separator: "/").count == 2 && isValidName($0) }.uniqued()
        var lines = taps.map { "tap \(quoted($0))" }
        lines += homebrew.filter { $0.provider == .homebrewFormula }.map { "brew \(quoted($0.qualifiedName))" }
        lines += homebrew.filter { $0.provider == .homebrewCask }.map { "cask \(quoted($0.qualifiedName))" }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Valid names never contain quotes or backslashes; escaping is defense in depth.
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
