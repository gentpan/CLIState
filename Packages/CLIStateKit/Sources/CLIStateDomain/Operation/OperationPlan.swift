import Foundation

public enum ServiceAction: String, Codable, Sendable, CaseIterable {
    case start, stop, restart
}

public enum OperationKind: Hashable, Codable, Sendable {
    case update
    case uninstall
    case service(ServiceAction)
    case refreshMetadata
    /// A native installer updating itself, e.g. `claude update`.
    case selfUpdate
    case cleanup(CleanupKind)
    /// Recoverable removal of a file no provider owns. Never `rm` (§159).
    case moveToTrash
    /// Installs packages that aren't on this Mac yet (environment restore, Lane N).
    case install
}

/// One step of a plan. Almost always a provider command; moving an unowned
/// file to the Trash is the only non-command mutation CLIState performs.
public enum OperationStep: Hashable, Codable, Sendable {
    case command(Command)
    case moveToTrash(path: String)

    public var displayString: String {
        switch self {
        case let .command(command): command.displayString
        case let .moveToTrash(path): "Move to Trash: \(path)"
        }
    }
}

public struct OperationTarget: Hashable, Codable, Sendable {
    public var toolID: ToolID?
    public var installationID: InstallationID?
    public var packageName: String
    public var displayName: String
    public var fromVersion: String?
    public var toVersion: String?

    public init(toolID: ToolID? = nil, installationID: InstallationID? = nil, packageName: String, displayName: String, fromVersion: String? = nil, toVersion: String? = nil) {
        self.toolID = toolID
        self.installationID = installationID
        self.packageName = packageName
        self.displayName = displayName
        self.fromVersion = fromVersion
        self.toVersion = toVersion
    }
}

/// A write operation before it runs. Built by a provider as pure data so the UI
/// can show the exact command and tests can assert it (§46, §177).
public struct OperationPlan: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: OperationKind
    public var providerID: ProviderID
    public var targets: [OperationTarget]
    /// Executed sequentially; stops at the first failure.
    public var steps: [OperationStep]
    public var requiresNetwork: Bool
    /// Plans sharing a scope run serially (§91). Defaults to the provider ID.
    public var mutationScope: String
    /// Who asked for it. Automatic plans only run for tools the user opted in.
    public var trigger: OperationTrigger

    public init(id: UUID = UUID(), kind: OperationKind, providerID: ProviderID, targets: [OperationTarget], steps: [OperationStep], requiresNetwork: Bool, mutationScope: String? = nil, trigger: OperationTrigger = .user) {
        self.id = id
        self.kind = kind
        self.providerID = providerID
        self.targets = targets
        self.steps = steps
        self.requiresNetwork = requiresNetwork
        self.mutationScope = mutationScope ?? providerID.rawValue
        self.trigger = trigger
    }

    public init(id: UUID = UUID(), kind: OperationKind, providerID: ProviderID, targets: [OperationTarget], commands: [Command], requiresNetwork: Bool, mutationScope: String? = nil, trigger: OperationTrigger = .user) {
        self.init(id: id, kind: kind, providerID: providerID, targets: targets, steps: commands.map(OperationStep.command), requiresNetwork: requiresNetwork, mutationScope: mutationScope, trigger: trigger)
    }

    public var commands: [Command] {
        steps.compactMap { if case let .command(command) = $0 { command } else { nil } }
    }
}

public enum OperationTrigger: String, Codable, Sendable {
    /// Explicit click and confirmation.
    case user
    /// Background run allowed by the user's auto-update policy.
    case automaticPolicy
}

public enum PreflightOutcome: String, Codable, Sendable {
    case passed, warning, failed, info
}

public enum PreflightKind: String, Codable, Sendable {
    case providerAvailable
    case providerUnchanged
    case installationPresent
    case ownershipConfirmed
    case writableLocation
    case networkRequired
    case dryRun
    case packageNameValid
    /// Installed packages that depend on the one being removed (§48).
    case reverseDependencies
    case systemManaged
    /// Selected leftovers include settings, credentials or history.
    case userData
}

public struct PreflightItem: Hashable, Codable, Sendable {
    public enum Change: String, Codable, Sendable {
        case install, upgrade, upgradeDependent, remove, dependent, reclaim
    }

    public var name: String
    public var change: Change
    public var fromVersion: String?
    public var toVersion: String?

    public init(name: String, change: Change, fromVersion: String? = nil, toVersion: String? = nil) {
        self.name = name
        self.change = change
        self.fromVersion = fromVersion
        self.toVersion = toVersion
    }
}

public struct PreflightCheck: Identifiable, Hashable, Codable, Sendable {
    public var id: String { kind.rawValue }
    public var kind: PreflightKind
    public var outcome: PreflightOutcome
    /// Short technical detail (paths, versions). Human wording comes from the UI layer.
    public var detail: String?
    public var items: [PreflightItem]

    public init(kind: PreflightKind, outcome: PreflightOutcome, detail: String? = nil, items: [PreflightItem] = []) {
        self.kind = kind
        self.outcome = outcome
        self.detail = detail
        self.items = items
    }

    public var isBlocking: Bool { outcome == .failed }
}

public enum OperationState: Hashable, Sendable {
    case pending
    case running
    case succeeded
    case failed(OperationFailure)
    case cancelled
}

public struct OperationFailure: Hashable, Codable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case preflightBlocked
        case commandFailed
        case permissionDenied
        case networkUnavailable
        case providerLocked
        case versionUnchanged
        case unknown
    }

    public var reason: Reason
    public var command: String?
    public var exitCode: Int32?

    public init(reason: Reason, command: String? = nil, exitCode: Int32? = nil) {
        self.reason = reason
        self.command = command
        self.exitCode = exitCode
    }
}

/// What CLIState records about operations it ran itself (§29). Full output is
/// kept only for the current session (§147).
public struct CommandHistoryEntry: Identifiable, Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running, succeeded, failed, cancelled, unverified, interrupted
    }

    public var id: UUID
    public var planKind: OperationKind
    public var trigger: OperationTrigger
    public var providerID: ProviderID
    public var commands: [String]
    public var targets: [OperationTarget]
    /// Version observed by the post-operation rescan.
    public var verifiedVersions: [String: String]
    public var status: Status
    public var exitCode: Int32?
    public var startedAt: Date
    public var finishedAt: Date?

    public init(id: UUID = UUID(), planKind: OperationKind, trigger: OperationTrigger = .user, providerID: ProviderID, commands: [String], targets: [OperationTarget], verifiedVersions: [String: String] = [:], status: Status, exitCode: Int32? = nil, startedAt: Date, finishedAt: Date? = nil) {
        self.id = id
        self.planKind = planKind
        self.trigger = trigger
        self.providerID = providerID
        self.commands = commands
        self.targets = targets
        self.verifiedVersions = verifiedVersions
        self.status = status
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}
