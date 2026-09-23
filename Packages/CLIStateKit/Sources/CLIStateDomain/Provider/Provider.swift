import Foundation

public struct ProviderAvailability: Hashable, Codable, Sendable {
    public var providerID: ProviderID
    public var isAvailable: Bool
    /// Resolved through the user's shell PATH, never hard-coded (§112).
    public var executable: String?
    public var version: String?
    public var reason: String?

    public init(providerID: ProviderID, isAvailable: Bool, executable: String? = nil, version: String? = nil, reason: String? = nil) {
        self.providerID = providerID
        self.isAvailable = isAvailable
        self.executable = executable
        self.version = version
        self.reason = reason
    }

    public static func unavailable(_ providerID: ProviderID, reason: String) -> ProviderAvailability {
        ProviderAvailability(providerID: providerID, isAvailable: false, reason: reason)
    }
}

public enum EnvironmentContext: Hashable, Codable, Sendable {
    case system
    case homebrew
    case nvm(version: String)
    case fnm(version: String)
    case mise(version: String?)
    case asdf(version: String?)
    case volta
    case standalone
    case custom(String)
}

public struct ProviderInstance: Hashable, Codable, Sendable {
    public var id: ProviderInstanceID
    public var providerID: ProviderID
    public var executable: String
    public var version: String?
    public var context: EnvironmentContext?

    public init(id: ProviderInstanceID, providerID: ProviderID, executable: String, version: String? = nil, context: EnvironmentContext? = nil) {
        self.id = id
        self.providerID = providerID
        self.executable = executable
        self.version = version
        self.context = context
    }
}

/// Filesystem roots a provider owns; the attribution engine matches resolved
/// executable paths against them.
public struct ProviderLayout: Hashable, Codable, Sendable {
    public var roots: [Key: String]

    public enum Key: String, Codable, Sendable, CodingKeyRepresentable {
        case homebrewPrefix, homebrewCellar, homebrewCaskroom
        case npmGlobalRoot, npmGlobalBin
        case uvToolDir, uvToolBinDir
        case pipxVenvs, pipxBinDir
        case pnpmGlobalRoot, pnpmGlobalBin
        case cargoHome, cargoBin
    }

    public init(roots: [Key: String] = [:]) {
        self.roots = roots
    }

    public subscript(key: Key) -> String? {
        get { roots[key] }
        set { roots[key] = newValue }
    }
}

public enum PackageKind: String, Codable, Sendable {
    case formula, cask, globalPackage, tool
}

/// Provider-native description of one installed package (§119). Not a UI model:
/// it must go through the merge engine to become a `Tool`.
public struct ProviderTool: Hashable, Codable, Sendable {
    public var providerID: ProviderID
    public var instanceID: ProviderInstanceID?
    public var packageName: String
    public var kind: PackageKind
    public var displayName: String?
    public var summary: String?
    public var homepage: String?
    public var installedVersions: [String]
    /// Linked / currently selected version when the provider knows it.
    public var activeVersion: String?
    public var latestVersion: String?
    /// The provider explicitly said outdated (highest-priority comparison, §118).
    public var isOutdated: Bool?
    public var isPinned: Bool
    public var installPrefix: String?
    /// Command names this package exposes (brew `bin/`, npm `bin`, uv entry points).
    public var executableNames: [String]
    /// Absolute executable paths when the provider reports them.
    public var executablePaths: [String]
    /// `nil` when unknown. Homebrew: `installed_on_request`.
    public var isDirect: Bool?
    public var isKegOnly: Bool
    public var dependencies: [String]
    public var installedAt: Date?
    /// Homebrew tap of a non-core package, e.g. `hashicorp/tap` (from `full_name`).
    public var tap: String?

    public init(
        providerID: ProviderID,
        instanceID: ProviderInstanceID? = nil,
        packageName: String,
        kind: PackageKind,
        displayName: String? = nil,
        summary: String? = nil,
        homepage: String? = nil,
        installedVersions: [String] = [],
        activeVersion: String? = nil,
        latestVersion: String? = nil,
        isOutdated: Bool? = nil,
        isPinned: Bool = false,
        installPrefix: String? = nil,
        executableNames: [String] = [],
        executablePaths: [String] = [],
        isDirect: Bool? = nil,
        isKegOnly: Bool = false,
        dependencies: [String] = [],
        installedAt: Date? = nil,
        tap: String? = nil
    ) {
        self.providerID = providerID
        self.instanceID = instanceID
        self.packageName = packageName
        self.kind = kind
        self.displayName = displayName
        self.summary = summary
        self.homepage = homepage
        self.installedVersions = installedVersions
        self.activeVersion = activeVersion
        self.latestVersion = latestVersion
        self.isOutdated = isOutdated
        self.isPinned = isPinned
        self.installPrefix = installPrefix
        self.executableNames = executableNames
        self.executablePaths = executablePaths
        self.isDirect = isDirect
        self.isKegOnly = isKegOnly
        self.dependencies = dependencies
        self.installedAt = installedAt
        self.tap = tap
    }

    public var installationID: InstallationID {
        .package(provider: providerID, instance: instanceID, name: packageName)
    }
}

public struct ProviderService: Hashable, Codable, Sendable {
    public var providerID: ProviderID
    public var name: String
    public var status: ServiceStatus
    public var rawStatus: String?
    public var user: String?
    public var plistPath: String?
    public var exitCode: Int?

    public init(providerID: ProviderID, name: String, status: ServiceStatus, rawStatus: String? = nil, user: String? = nil, plistPath: String? = nil, exitCode: Int? = nil) {
        self.providerID = providerID
        self.name = name
        self.status = status
        self.rawStatus = rawStatus
        self.user = user
        self.plistPath = plistPath
        self.exitCode = exitCode
    }
}

public enum ScanDepth: String, Codable, Sendable {
    /// Local data only: installed packages, services, cached latest versions (§43).
    case fast
    /// Adds network-backed update checks (`npm outdated`, `uv tool list --outdated`).
    case deep
}

public struct ProviderInventory: Sendable {
    public var providerID: ProviderID
    public var availability: ProviderAvailability
    public var instance: ProviderInstance?
    public var layout: ProviderLayout
    public var tools: [ProviderTool]
    public var services: [ProviderService]
    public var depth: ScanDepth
    public var scannedAt: Date
    /// Non-fatal problems, e.g. Homebrew "untrusted tap" warnings on stderr.
    public var warnings: [String]
    /// When the provider's local package index was last downloaded (`brew update`).
    /// `nil` for providers that query their registry online on every check.
    public var metadataUpdatedAt: Date?

    public init(providerID: ProviderID, availability: ProviderAvailability, instance: ProviderInstance? = nil, layout: ProviderLayout = ProviderLayout(), tools: [ProviderTool] = [], services: [ProviderService] = [], depth: ScanDepth, scannedAt: Date, warnings: [String] = [], metadataUpdatedAt: Date? = nil) {
        self.providerID = providerID
        self.availability = availability
        self.instance = instance
        self.layout = layout
        self.tools = tools
        self.services = services
        self.depth = depth
        self.scannedAt = scannedAt
        self.warnings = warnings
        self.metadataUpdatedAt = metadataUpdatedAt
    }
}

/// Everything a provider needs from the environment. Providers resolve their own
/// executable through `discovery.binaries`, never via hard-coded paths.
public struct ProviderContext: Sendable {
    public var discovery: DiscoveryResult
    public var now: Date

    public init(discovery: DiscoveryResult, now: Date) {
        self.discovery = discovery
        self.now = now
    }

    public var execution: ExecutionEnvironment { discovery.session.execution }

    /// `command -v <name>` against the user's shell PATH.
    public func resolveExecutable(_ name: String) -> String? {
        discovery.binaries.candidates(named: name).first?.path
    }
}

public enum ProviderError: Error, Equatable, Sendable {
    case unavailable(ProviderID)
    case commandFailed(ProviderID, command: String, exitCode: Int32, stderr: String)
    case parsingFailed(ProviderID, what: String)
    /// Rejected before building a command, e.g. a package name starting with `-`.
    case invalidPackageName(String)
    case unsupportedOperation
}

// MARK: - Capability protocols (§70)

/// Base capability: detect and read.
public protocol ToolProvider: Sendable {
    var id: ProviderID { get }
    func availability(context: ProviderContext) async -> ProviderAvailability
    /// Must not mutate anything. Homebrew calls set `HOMEBREW_NO_AUTO_UPDATE=1` (F1).
    func scan(context: ProviderContext, depth: ScanDepth) async throws -> ProviderInventory
}

/// Write capabilities only build plans; the application layer executes them (C2).
public protocol ToolUpdateProvider: ToolProvider {
    func updatePlan(for tools: [ProviderTool], context: ProviderContext) throws -> OperationPlan
}

public protocol ToolUninstallProvider: ToolProvider {
    func uninstallPlan(for tool: ProviderTool, context: ProviderContext) throws -> OperationPlan
}

public protocol ServiceProvider: ToolProvider {
    func servicePlan(_ action: ServiceAction, service: ProviderService, context: ProviderContext) throws -> OperationPlan
}

public protocol MetadataRefreshProvider: ToolProvider {
    /// e.g. `brew update` — a provider-level maintenance mutation (§128).
    func refreshMetadataPlan(context: ProviderContext) throws -> OperationPlan
}

public protocol OperationPreflightProvider: ToolProvider {
    /// Provider-specific read-only checks, e.g. `brew upgrade --dry-run` (F11).
    func preflight(for plan: OperationPlan, context: ProviderContext) async -> [PreflightCheck]
}
