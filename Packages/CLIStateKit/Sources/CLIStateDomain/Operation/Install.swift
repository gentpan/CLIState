import Foundation

/// One package to install. Provider-agnostic: the provider is chosen by the
/// `OperationRequest.install` it travels in.
public struct InstallRequest: Hashable, Codable, Sendable {
    /// Provider-native name without the tap: `terraform`, `@openai/codex`.
    public var packageName: String
    public var kind: PackageKind
    /// Homebrew only, e.g. `hashicorp/tap`. Added with an explicit `brew tap` step.
    public var tap: String?
    public var toolID: ToolID?
    public var displayName: String

    public init(packageName: String, kind: PackageKind, tap: String? = nil, toolID: ToolID? = nil, displayName: String? = nil) {
        self.packageName = packageName
        self.kind = kind
        self.tap = tap
        self.toolID = toolID
        self.displayName = displayName ?? packageName
    }

    public init(item: ProfileItem) {
        self.init(packageName: item.packageName, kind: item.provider.packageKind ?? .tool, tap: item.tap, toolID: item.toolID)
    }

    /// Name passed to the package manager: `hashicorp/tap/terraform` for tapped formulae.
    public var qualifiedName: String {
        guard let tap, !tap.isEmpty else { return packageName }
        return "\(tap)/\(packageName)"
    }
}

/// Install capability (Lane N). Like every write capability it only builds a
/// plan; `OperationCoordinator` confirms, runs, rescans and verifies it (C2).
public protocol ToolInstallProvider: ToolProvider {
    /// Latest version of each package, no version pinning. Throws
    /// `ProviderError.invalidPackageName` before building any command for a bad name.
    func installPlan(for packages: [InstallRequest], context: ProviderContext) throws -> OperationPlan
}
