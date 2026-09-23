import CLIStateDomain
import Foundation

/// Marks changes that an operation CLIState ran explains. A history entry explains
/// a change when it ran between the two scans, targeted the same tool,
/// installation, path or service, and its kind can cause that change.
public struct ChangeAttributor: Sendable {
    public init() {}

    /// - Parameters:
    ///   - since: capture time of the previous snapshot (`nil`: no lower bound).
    ///   - until: capture time of the snapshot that revealed the changes.
    public func attribute(_ changes: [EnvironmentChange], history: [CommandHistoryEntry], since: Date?, until: Date) -> [EnvironmentChange] {
        // An operation still running has no finish time yet; it may have caused what this scan saw.
        let candidates = history
            .filter { entry in
                entry.startedAt <= until && (since.map { (entry.finishedAt ?? until) >= $0 } ?? true)
            }
            .sorted { $0.startedAt > $1.startedAt }
        guard !candidates.isEmpty else { return changes }
        return changes.map { change in
            var change = change
            if let entry = candidates.first(where: { Self.explains($0, change) }) {
                change.origin = ChangeOrigin(kind: .clistate, historyEntryID: entry.id, operation: entry.planKind, trigger: entry.trigger)
            }
            return change
        }
    }

    static func explains(_ entry: CommandHistoryEntry, _ change: EnvironmentChange) -> Bool {
        guard compatible(entry.planKind, change.kind) else { return false }
        if case .service = entry.planKind {
            return entry.targets.contains { target in
                target.packageName == change.subject || (target.toolID != nil && target.toolID == change.toolID)
            }
        }
        // `brew update` also updates Homebrew itself; the plan has no targets.
        if entry.planKind == .refreshMetadata {
            return change.toolID?.rawValue == entry.providerID.rawValue
        }
        let trashed = Set(entry.commands.compactMap(Self.trashedPath))
        if entry.targets.contains(where: { targets($0, change) }) { return true }
        if let installation = change.installationID?.rawValue, installation.hasPrefix("path:"), trashed.contains(String(installation.dropFirst(5))) {
            return true
        }
        if change.kind == .activeExecutableChanged, let from = change.from, trashed.contains(from) {
            return true
        }
        // `brew upgrade php` also upgrades the formulae php depends on.
        if entry.planKind == .update, change.kind == .versionChanged, change.category == .dependency, change.provider == entry.providerID {
            return true
        }
        return false
    }

    private static func targets(_ target: OperationTarget, _ change: EnvironmentChange) -> Bool {
        if let id = target.installationID, id == change.installationID { return true }
        if let tool = target.toolID, tool == change.toolID { return true }
        // Move to Trash targets carry only the path.
        if target.toolID == nil, target.installationID == nil, change.installationID == .path(target.packageName) { return true }
        return false
    }

    private static func compatible(_ kind: OperationKind, _ change: EnvironmentChangeKind) -> Bool {
        switch kind {
        case .update, .selfUpdate:
            [.versionChanged, .activeExecutableChanged, .installationAdded, .installationRemoved].contains(change)
        case .install:
            [.toolAdded, .installationAdded, .activeExecutableChanged].contains(change)
        case .uninstall, .moveToTrash:
            [.installationRemoved, .toolRemoved, .activeExecutableChanged].contains(change)
        case let .cleanup(cleanup):
            [.brokenSymlink, .orphanedDependencies, .oldVersions, .unusedRuntime].contains(cleanup)
                && [.installationRemoved, .toolRemoved, .activeExecutableChanged].contains(change)
        case .service:
            [.serviceStarted, .serviceStopped].contains(change)
        case .refreshMetadata:
            change == .versionChanged
        }
    }

    /// `OperationStep.displayString` of a trash step: `Move to Trash: <path>`.
    private static func trashedPath(_ command: String) -> String? {
        let prefix = "Move to Trash: "
        return command.hasPrefix(prefix) ? String(command.dropFirst(prefix.count)) : nil
    }
}
