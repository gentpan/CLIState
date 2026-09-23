import CLIStateDomain
import SwiftUI

/// Localized titles, explanations and result messages for write operations.
enum OperationText {
    static func title(for operation: PreparedOperation) -> String {
        let plans = operation.plans.map(\.plan)
        if plans.count > 1 {
            if plans.allSatisfy({ isUpdate($0.kind) }) {
                let count = operation.allTargets.count
                return String(localized: "Update \(count) tools")
            }
            if plans.allSatisfy({ $0.kind == .install }) {
                return RestoreText.installTitle(count: operation.allTargets.count)
            }
            return String(localized: "Run \(plans.count) operations")
        }
        guard let plan = plans.first else { return "" }
        return title(for: plan)
    }

    static func title(for plan: OperationPlan) -> String {
        let name = targetName(plan)
        let provider = plan.providerID.displayName
        switch plan.kind {
        case .update, .selfUpdate:
            if plan.targets.count > 1 {
                let count = plan.targets.count
                return String(localized: "Update \(count) tools")
            }
            return String(localized: "Update \(name)")
        case .uninstall:
            if plan.steps.contains(where: \.isMoveToTrash) {
                return String(localized: "Uninstall and Clean Up \(name)", table: "Tools")
            }
            return String(localized: "Uninstall \(name)")
        case let .service(action):
            return action.title(for: name)
        case .refreshMetadata:
            return String(localized: "Refresh \(provider) metadata")
        case let .cleanup(kind):
            switch kind {
            case .providerCache: return String(localized: "Clear \(provider) cache")
            case .oldVersions: return String(localized: "Clean up \(provider)")
            case .orphanedDependencies: return String(localized: "Remove unused \(provider) dependencies")
            case .brokenSymlink: return String(localized: "Move broken links to the Trash")
            case .unusedRuntime: return String(localized: "Remove unused runtime")
            case .leftovers: return String(localized: "Clean Up \(name) Leftovers", table: "Tools")
            }
        case .install:
            return RestoreText.installTitle(plan, name: name)
        case .moveToTrash:
            let count = plan.steps.count
            if count == 1, !name.isEmpty {
                return String(localized: "Move \(name) to the Trash")
            }
            return String(localized: "Move \(count) items to the Trash")
        }
    }

    static func confirmTitle(for operation: PreparedOperation) -> String {
        guard let plan = operation.plans.first?.plan else { return String(localized: "Continue") }
        switch plan.kind {
        case .update, .selfUpdate:
            // States the action and its size, e.g. "Update 12 Packages".
            let count = operation.allTargets.count
            return count > 1 ? String(localized: "Update \(count) Tools") : String(localized: "Update")
        case .uninstall: return String(localized: "Uninstall")
        case let .service(action): return action.title
        case .refreshMetadata: return String(localized: "Refresh")
        case .cleanup(.brokenSymlink), .cleanup(.leftovers), .moveToTrash: return String(localized: "Move to Trash")
        case .cleanup: return String(localized: "Clean Up")
        case .install: return RestoreText.installConfirmTitle(count: operation.allTargets.count)
        }
    }

    static func explanation(for operation: PreparedOperation) -> String {
        guard let plan = operation.plans.first?.plan else { return "" }
        let provider = plan.providerID.displayName
        switch plan.kind {
        case .update, .selfUpdate:
            return String(localized: "CLI State runs the commands below, then rescans to confirm the new versions.")
        case .uninstall:
            if plan.steps.contains(where: \.isMoveToTrash) {
                return String(localized: "\(provider) removes the package and its links, then the selected leftover files are moved to the Trash.", table: "Tools")
            }
            return String(localized: "\(provider) removes the package and its links. This can't be undone from CLI State.")
        case .service(.start):
            return String(localized: "\(provider) starts the service and keeps it running at login.")
        case .service:
            return String(localized: "Apps connected to this service may be interrupted.")
        case .refreshMetadata:
            return String(localized: "Downloads the latest package information. Nothing is installed or upgraded.")
        case .cleanup(.brokenSymlink), .cleanup(.leftovers), .moveToTrash:
            return String(localized: "Items are moved to the Trash, not deleted, so you can put them back.")
        case .cleanup:
            return String(localized: "Only the items previewed by the dry run below are removed.")
        case .install:
            return RestoreText.installExplanation
        }
    }

    static func isDestructive(_ kind: OperationKind) -> Bool {
        switch kind {
        case .uninstall, .cleanup, .moveToTrash: true
        case .update, .selfUpdate, .service, .refreshMetadata, .install: false
        }
    }

    static func symbol(for kind: OperationKind) -> String {
        switch kind {
        case .update, .selfUpdate: Symbol.update
        case .uninstall, .moveToTrash: Symbol.trash
        case let .service(action): action.symbol
        case .refreshMetadata: Symbol.refresh
        case let .cleanup(kind): kind.symbol
        case .install: RestoreSymbol.install
        }
    }

    /// `brew upgrade php`, or a localized description for non-command steps.
    static func stepText(_ step: OperationStep) -> String {
        switch step {
        case let .command(command): command.displayString
        case let .moveToTrash(path): String(localized: "Move to Trash: \(path)")
        }
    }

    static func resultState(plan: OperationPlan, outcome: OperationOutcome) -> ActivityRun.State {
        let name = targetName(plan)
        let provider = plan.providerID.displayName
        switch outcome {
        case let .succeeded(verified):
            switch plan.kind {
            case .update, .selfUpdate:
                if plan.targets.count == 1, let target = plan.targets.first,
                   let version = verified[target.packageName] ?? target.toVersion {
                    return .succeeded(message: String(localized: "Updated to \(version)"))
                }
                let count = plan.targets.count
                return .succeeded(message: String(localized: "Updated \(count) tools"))
            case .uninstall:
                return .succeeded(message: String(localized: "Removed the \(provider) installation of \(name)"))
            case .service(.start):
                return .succeeded(message: String(localized: "\(name) started"))
            case .service(.stop):
                return .succeeded(message: String(localized: "\(name) stopped"))
            case .service(.restart):
                return .succeeded(message: String(localized: "\(name) restarted"))
            case .refreshMetadata:
                return .succeeded(message: String(localized: "Package info refreshed"))
            case .cleanup(.brokenSymlink), .cleanup(.leftovers), .moveToTrash:
                return .succeeded(message: String(localized: "Moved to the Trash"))
            case .cleanup:
                return .succeeded(message: String(localized: "Cleanup finished"))
            case .install:
                return .succeeded(message: RestoreText.installSucceeded(plan))
            }
        case .unverified:
            return .attention(message: String(localized: "Command finished, but the result couldn't be verified. Scan again to check."))
        case .versionUnchanged where plan.kind == .install:
            return .attention(message: RestoreText.installUnverified)
        case .versionUnchanged:
            return .attention(message: String(localized: "Command finished, but the version didn't change"))
        case .cancelled:
            return .attention(message: String(localized: "Cancelled"))
        case let .failed(failure):
            switch failure.reason {
            case .networkUnavailable:
                return .failed(message: String(localized: "\(name) couldn't be changed because the network is unavailable. Check your connection, then try again."))
            case .permissionDenied:
                return .failed(message: String(localized: "\(name) couldn't be changed because permission was denied. CLI State never uses sudo, so check the permissions of the install location."))
            case .providerLocked:
                return .failed(message: String(localized: "\(provider) is busy with another operation. Try again when it finishes."))
            case .preflightBlocked:
                return .failed(message: String(localized: "A preflight check failed, so nothing was changed. Review the checks, then try again."))
            case .versionUnchanged:
                return .attention(message: String(localized: "Command finished, but the version didn't change"))
            case .commandFailed, .unknown:
                switch plan.kind {
                case .update, .selfUpdate:
                    return .failed(message: String(localized: "\(name) couldn't be updated because \(provider) returned an error. View the output for details."))
                case .uninstall:
                    return .failed(message: String(localized: "\(name) couldn't be uninstalled because \(provider) returned an error. View the output for details."))
                case .service:
                    return .failed(message: String(localized: "The service action for \(name) failed because \(provider) returned an error. View the output for details."))
                case .refreshMetadata:
                    return .failed(message: String(localized: "Package info couldn't be refreshed because \(provider) returned an error. View the output for details."))
                case .cleanup, .moveToTrash:
                    return .failed(message: String(localized: "Cleanup couldn't finish because \(provider) returned an error. View the output for details."))
                case .install:
                    return .failed(message: RestoreText.installFailed(name: name, provider: provider))
                }
            }
        }
    }

    static func historyTitle(_ entry: CommandHistoryEntry) -> String {
        let plan = OperationPlan(id: entry.id, kind: entry.planKind, providerID: entry.providerID, targets: entry.targets, steps: entry.commands.map { _ in .command(Command(executable: "")) }, requiresNetwork: false)
        return title(for: plan)
    }

    private static func isUpdate(_ kind: OperationKind) -> Bool {
        kind == .update || kind == .selfUpdate
    }

    private static func targetName(_ plan: OperationPlan) -> String {
        if plan.targets.count == 1, let target = plan.targets.first { return target.displayName }
        return plan.targets.map(\.displayName).formatted(.list(type: .and))
    }
}

extension OperationStep {
    var isMoveToTrash: Bool {
        if case .moveToTrash = self { return true }
        return false
    }
}
