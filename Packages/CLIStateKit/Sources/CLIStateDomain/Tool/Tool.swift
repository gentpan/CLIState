import Foundation

public enum ToolCategory: String, CaseIterable, Codable, Sendable {
    case runtime
    case aiCLI
    case developerTool
    case database
    case packageManager
    /// Installed only because something else needs it; hidden by default.
    case dependency
    /// Executable found in PATH that no provider or registry entry explains (§41).
    case unrecognized
}

public struct ToolIdentity: Hashable, Codable, Sendable {
    public var name: String
    public var displayName: String
    /// English summary from the registry or provider metadata.
    public var summary: String?
    public var category: ToolCategory
    public var homepage: URL?
    public var documentationURL: URL?
    /// Registry definition this tool matched, if any.
    public var registryID: String?

    public init(name: String, displayName: String, summary: String? = nil, category: ToolCategory, homepage: URL? = nil, documentationURL: URL? = nil, registryID: String? = nil) {
        self.name = name
        self.displayName = displayName
        self.summary = summary
        self.category = category
        self.homepage = homepage
        self.documentationURL = documentationURL
        self.registryID = registryID
    }
}

public enum AttributionConfidence: String, Codable, Sendable, Comparable {
    case unknown
    case probable
    case confirmed

    private var rank: Int {
        switch self {
        case .unknown: 0
        case .probable: 1
        case .confirmed: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public enum AttributionEvidence: Hashable, Codable, Sendable {
    /// e.g. `brew info --installed` lists `php`.
    case inventoryContains(provider: ProviderID, package: String)
    /// Symlink resolves inside a provider-owned prefix, e.g. `/opt/homebrew/Cellar/php/`.
    case symlinkResolvesInto(String)
    /// Registry-known install layout, e.g. `~/.local/share/claude/versions/`.
    case knownLayout(String)
    /// Version reported by the executable equals the version implied by its path.
    case versionMatches(String)
    /// Weak: the containing directory only. Never sufficient on its own (§37).
    case pathDirectory(String)
    case systemLocation(String)
}

public struct Ownership: Hashable, Codable, Sendable {
    public var provider: ProviderID
    public var instance: ProviderInstanceID?
    public var packageName: String?
    public var confidence: AttributionConfidence
    public var evidence: [AttributionEvidence]

    public init(provider: ProviderID, instance: ProviderInstanceID? = nil, packageName: String? = nil, confidence: AttributionConfidence, evidence: [AttributionEvidence] = []) {
        self.provider = provider
        self.instance = instance
        self.packageName = packageName
        self.confidence = confidence
        self.evidence = evidence
    }

    /// Write operations require confirmed ownership (§160).
    public var permitsMutation: Bool { confidence == .confirmed }
}

public struct ExecutableRef: Hashable, Codable, Sendable {
    public var name: String
    public var path: String
    public var resolvedPath: String?
    /// 1-based PATH priority when the executable is reachable through PATH.
    public var pathPriority: Int?
    public var architecture: CPUArchitecture?

    public init(name: String, path: String, resolvedPath: String? = nil, pathPriority: Int? = nil, architecture: CPUArchitecture? = nil) {
        self.name = name
        self.path = path
        self.resolvedPath = resolvedPath
        self.pathPriority = pathPriority
        self.architecture = architecture
    }
}

public enum LinkState: String, Codable, Sendable {
    /// First match in PATH for the tool's primary command.
    case active
    /// In PATH, but an earlier entry wins.
    case shadowed
    /// Installed but not reachable through PATH (e.g. keg-only `php@8.2`).
    case notOnPath
    /// Executable or its symlink target is missing.
    case broken
}

public struct ToolCapabilities: Hashable, Codable, Sendable {
    public var canUpdate: Bool
    public var canUninstall: Bool
    public var canStart: Bool
    public var canStop: Bool
    public var canRestart: Bool
    public var canSwitchVersion: Bool
    public var canOpenConfig: Bool
    /// Unowned executables and broken links can be moved to the Trash (never deleted).
    public var canMoveToTrash: Bool

    public init(canUpdate: Bool = false, canUninstall: Bool = false, canStart: Bool = false, canStop: Bool = false, canRestart: Bool = false, canSwitchVersion: Bool = false, canOpenConfig: Bool = false, canMoveToTrash: Bool = false) {
        self.canUpdate = canUpdate
        self.canUninstall = canUninstall
        self.canStart = canStart
        self.canStop = canStop
        self.canRestart = canRestart
        self.canSwitchVersion = canSwitchVersion
        self.canOpenConfig = canOpenConfig
        self.canMoveToTrash = canMoveToTrash
    }

    public static let none = ToolCapabilities()
}

/// Measured size of an installation.
public struct DiskUsage: Hashable, Codable, Sendable {
    public var bytes: Int64
    public var measuredAt: Date
    /// Version the measurement belongs to; a different installed version needs a new one.
    public var version: String?
    /// The walk stopped at its file limit, so `bytes` is a lower bound.
    public var isPartial: Bool

    public init(bytes: Int64, measuredAt: Date, version: String?, isPartial: Bool = false) {
        self.bytes = bytes
        self.measuredAt = measuredAt
        self.version = version
        self.isPartial = isPartial
    }
}

public struct ToolInstallation: Identifiable, Hashable, Codable, Sendable {
    public var id: InstallationID
    public var ownership: Ownership
    public var version: ObservedValue<ToolVersion>?
    public var latest: ObservedValue<ToolVersion>?
    /// Release channel the latest version came from, e.g. `latest`, `stable`.
    public var latestChannel: String?
    public var executables: [ExecutableRef]
    public var installPrefix: String?
    public var linkState: LinkState
    /// `installed_on_request` for Homebrew; `nil` when the provider cannot tell.
    public var isDirect: Bool?
    public var isSystemManaged: Bool
    public var capabilities: ToolCapabilities
    public var dependencies: [String]
    public var dependents: [String]
    public var installedAt: Date?
    /// Existing configuration files or directories.
    public var configPaths: [String]
    /// Release-cycle support from endoflife.date, for registry runtimes and databases.
    public var support: RuntimeSupportStatus? = nil
    /// Bytes the installation occupies on disk (its prefix, package directory or binaries).
    /// `nil` until measured; measuring walks the disk, so fast scans carry it forward.
    public var diskUsage: DiskUsage? = nil
    /// When the primary executable was last run, from its access time. `nil` when unknown,
    /// e.g. on the read-only system volume. Never set from CLI State's own version probes.
    public var lastUsedAt: Date? = nil

    public init(
        id: InstallationID,
        ownership: Ownership,
        version: ObservedValue<ToolVersion>? = nil,
        latest: ObservedValue<ToolVersion>? = nil,
        latestChannel: String? = nil,
        executables: [ExecutableRef] = [],
        installPrefix: String? = nil,
        linkState: LinkState,
        isDirect: Bool? = nil,
        isSystemManaged: Bool = false,
        capabilities: ToolCapabilities = .none,
        dependencies: [String] = [],
        dependents: [String] = [],
        installedAt: Date? = nil,
        configPaths: [String] = []
    ) {
        self.id = id
        self.ownership = ownership
        self.version = version
        self.latest = latest
        self.latestChannel = latestChannel
        self.executables = executables
        self.installPrefix = installPrefix
        self.linkState = linkState
        self.isDirect = isDirect
        self.isSystemManaged = isSystemManaged
        self.capabilities = capabilities
        self.dependencies = dependencies
        self.dependents = dependents
        self.installedAt = installedAt
        self.configPaths = configPaths
    }

    public var hasUpdate: Bool {
        guard let current = version?.value.semantic, let newest = latest?.value.semantic else {
            if let current = version?.value.rawValue, let newest = latest?.value.rawValue { return current != newest }
            return false
        }
        return current < newest
    }

    public var updateKind: UpdateKind {
        guard let current = version?.value, let newest = latest?.value else { return .unknown }
        return UpdateKind.between(current, newest)
    }
}

/// How the terminal resolves a tool's primary command.
public struct CommandResolution: Hashable, Codable, Sendable {
    public var command: String
    /// Every PATH match in priority order; the first one runs.
    public var chain: [ExecutableRef]
    /// Aliases/functions that run before any PATH lookup.
    public var shadows: [ShellShadow]

    public init(command: String, chain: [ExecutableRef], shadows: [ShellShadow] = []) {
        self.command = command
        self.chain = chain
        self.shadows = shadows
    }
}

public enum ServiceStatus: String, Codable, Sendable {
    case running, stopped, scheduled, error, unknown
}

public struct ToolService: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var providerID: ProviderID
    public var status: ServiceStatus
    public var rawStatus: String?
    public var toolID: ToolID?
    public var installationID: InstallationID?
    public var user: String?
    public var plistPath: String?
    public var exitCode: Int?

    public init(id: String, name: String, providerID: ProviderID, status: ServiceStatus, rawStatus: String? = nil, toolID: ToolID? = nil, installationID: InstallationID? = nil, user: String? = nil, plistPath: String? = nil, exitCode: Int? = nil) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.status = status
        self.rawStatus = rawStatus
        self.toolID = toolID
        self.installationID = installationID
        self.user = user
        self.plistPath = plistPath
        self.exitCode = exitCode
    }
}

public enum ToolHealth: String, Codable, Sendable {
    case healthy, updateAvailable, duplicateInstallation, pathConflict, broken, unsupported, unknown
}

public struct ToolHealthState: Hashable, Codable, Sendable {
    public var status: ToolHealth
    public var issueIDs: [String]

    public init(status: ToolHealth, issueIDs: [String] = []) {
        self.status = status
        self.issueIDs = issueIDs
    }
}

/// Canonical tool: one identity, many installations (§77, §116).
public struct Tool: Identifiable, Hashable, Codable, Sendable {
    public var id: ToolID
    public var identity: ToolIdentity
    public var installations: [ToolInstallation]
    public var activeInstallationID: InstallationID?
    public var resolution: CommandResolution?
    public var service: ToolService?
    public var health: ToolHealthState
    public var lastScannedAt: Date

    public init(id: ToolID, identity: ToolIdentity, installations: [ToolInstallation], activeInstallationID: InstallationID? = nil, resolution: CommandResolution? = nil, service: ToolService? = nil, health: ToolHealthState, lastScannedAt: Date) {
        self.id = id
        self.identity = identity
        self.installations = installations
        self.activeInstallationID = activeInstallationID
        self.resolution = resolution
        self.service = service
        self.health = health
        self.lastScannedAt = lastScannedAt
    }

    public var activeInstallation: ToolInstallation? {
        guard let activeInstallationID else { return nil }
        return installations.first { $0.id == activeInstallationID }
    }

    /// The installation to feature in lists: the active one, else the first managed one.
    public var primaryInstallation: ToolInstallation? {
        activeInstallation ?? installations.first { !$0.isSystemManaged } ?? installations.first
    }

    public var hasUpdate: Bool { installations.contains { $0.hasUpdate } }
}
