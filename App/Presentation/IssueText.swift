import CLIStateDomain
import Foundation
import SwiftUI

struct IssueText: Hashable {
    let title: String
    let message: String
}

extension HealthIssue {
    /// Localized explanation built from `type`, `subject` and `details`.
    func text(in snapshot: EnvironmentSnapshot?) -> IssueText {
        let tool = toolID.flatMap { snapshot?.tool($0) }
        let name = tool?.identity.displayName ?? subject
        let provider = ProviderID(subject).displayName
        // The command itself (`codexbar`), not the tool ID (`homebrew.codexbar`).
        let command = paths.first.map { ($0 as NSString).lastPathComponent } ?? tool?.resolution?.command ?? name

        switch type {
        case .pathConflict:
            let title = String(localized: "Conflicting installations of \(name)")
            if let tool, let chain = tool.resolution?.chain, chain.count > 1,
               let active = tool.installation(forExecutablePath: chain[0].path),
               let shadowed = tool.installation(forExecutablePath: chain[1].path) {
                let activeProvider = active.ownership.provider.displayName
                let activeVersion = active.versionText
                let shadowedProvider = shadowed.ownership.provider.displayName
                let shadowedVersion = shadowed.versionText
                return IssueText(
                    title: title,
                    message: String(localized: "Terminal runs the \(activeProvider) installation (\(activeVersion)). The \(shadowedProvider) installation (\(shadowedVersion)) comes later in PATH, so it's shadowed, and updating it won't change what runs.")
                )
            }
            return IssueText(title: title, message: String(localized: "Several installations provide \(subject). Terminal runs the first one in PATH; the others are shadowed."))

        case .duplicateInstallation:
            let count = tool?.installations.count ?? installationIDs.count
            return IssueText(
                title: String(localized: "Multiple installations of \(name)"),
                message: String(localized: "\(count) installations were found. Updating one doesn't change the others.")
            )

        case .missingPathEntry:
            let priority = details["priority"] ?? "—"
            return IssueText(
                title: String(localized: "PATH entry doesn't exist"),
                message: String(localized: "Entry #\(priority) points to a directory that doesn't exist. It's often left behind by an app that was removed, and it slows down every command lookup a little.")
            )

        case .duplicatePathEntry:
            let first = details["duplicateOf"] ?? "—"
            let priority = details["priority"] ?? "—"
            return IssueText(
                title: String(localized: "Duplicate PATH entry"),
                message: String(localized: "Entry #\(priority) repeats entry #\(first). Only the first occurrence has an effect, so this one can be removed from your shell configuration.")
            )

        case .relativePathEntry:
            return IssueText(
                title: String(localized: "Relative PATH entry"),
                message: String(localized: "This entry is relative, so what it finds depends on the current directory.")
            )

        case .missingRuntime:
            let runtime = details["runtime"] ?? "—"
            return IssueText(
                title: String(localized: "\(name) needs a missing runtime"),
                message: String(localized: "\(subject) is installed, but \(runtime) can't be found in PATH.")
            )

        case .brokenSymlink:
            // The engine reports one issue per link: paths = [link, missing destination].
            let link = (subject as NSString).lastPathComponent
            let home = snapshot?.shell.variables["HOME"] ?? NSHomeDirectory()
            let destination = paths.dropFirst().first.map { PathRedaction.abbreviatingHome($0, home: home) } ?? "?"
            if severity == .info {
                return IssueText(
                    title: String(localized: "Broken link: \(link)"),
                    message: String(localized: "This macOS-managed link points to \(destination), which is currently unavailable. Do not remove the system link manually.")
                )
            }
            return IssueText(
                title: String(localized: "Broken link: \(link)"),
                message: String(localized: "It points to \(destination), which no longer exists. This can happen after its app is removed. Check the resolution below before changing the link.")
            )

        case .brokenActiveExecutable:
            return IssueText(
                title: String(localized: "\(name) can't run"),
                message: String(localized: "The file Terminal finds for \(command) points to something that no longer exists.")
            )

        case .failedService:
            return IssueText(
                title: String(localized: "Service \(subject) failed"),
                message: String(localized: "The service exited with an error. Check its log, then restart it.")
            )

        case .providerUnavailable:
            return IssueText(
                title: String(localized: "\(provider) isn't available"),
                message: String(localized: "\(provider) couldn't be found in your shell's PATH, so its packages aren't listed.")
            )

        case .providerScanFailed:
            return IssueText(
                title: String(localized: "\(provider) couldn't be scanned"),
                message: String(localized: "The last scan of \(provider) failed. CLI State shows the most recent data that was available.")
            )

        case .mixedArchitecture:
            return IssueText(
                title: String(localized: "\(name) uses a different architecture"),
                message: String(localized: "Some installations of \(subject) are built for Intel and run under Rosetta.")
            )

        case .runtimeEndOfLife:
            return EndOfLifeText.issue(self, name: name)

        case .shellShadowing:
            return IssueText(
                title: String(localized: "A shell alias overrides \(subject)"),
                message: String(localized: "Your shell runs an alias or function named \(subject) before looking in PATH, so the tool shown here may not be what runs.")
            )
        }
    }
}

extension SuggestedAction {
    var title: String? {
        switch self {
        case .openPathSettings: String(localized: "Show PATH")
        case .revealInFinder: String(localized: "Reveal in Finder")
        case .updateTool: String(localized: "Update")
        case .restartService: String(localized: "Restart Service")
        case .openTool: String(localized: "Show Tool")
        case .none: nil
        }
    }

    var symbol: String {
        switch self {
        case .openPathSettings: Symbol.path
        case .revealInFinder: Symbol.reveal
        case .updateTool: Symbol.update
        case .restartService: Symbol.restart
        case .openTool: Symbol.tools
        case .none: Symbol.info
        }
    }
}

extension HealthIssue {
    var handlingAdvice: String {
        switch type {
        case .pathConflict, .duplicateInstallation:
            String(localized: "Compare the installations and choose which one to keep. Remove an extra copy only after checking its dependents; do not remove the macOS copy.")
        case .missingPathEntry:
            String(localized: "Check whether the directory should still exist. If it belongs to removed software, remove its PATH entry from the configuration that added it.")
        case .duplicatePathEntry:
            String(localized: "Keep the first occurrence and remove later duplicates in the source configuration. CLI State does not yet locate or edit that configuration automatically.")
        case .relativePathEntry:
            String(localized: "Replace this entry with an absolute directory path in your shell configuration.")
        case .missingRuntime:
            String(localized: "Install the required runtime using the package manager for this tool, then check again.")
        case .brokenSymlink, .brokenActiveExecutable:
            String(localized: "If you still use this tool, repair or reinstall it first. Otherwise, a confirmed broken link can be moved to the Trash using the handling button.")
        case .failedService:
            String(localized: "Inspect the service log before restarting. Restarting may briefly interrupt the tools that depend on it.")
        case .providerUnavailable:
            String(localized: "Check that the package manager is installed and its directory is in PATH, then scan again.")
        case .providerScanFailed:
            String(localized: "Retry the scan. If it still fails, check the reported error and the package manager in Terminal.")
        case .mixedArchitecture:
            String(localized: "Prefer a native build for this Mac. Keep the Intel installation if an existing project depends on it.")
        case .runtimeEndOfLife:
            String(localized: "Review project compatibility before upgrading to a supported runtime. An available update may not resolve end-of-life status.")
        case .shellShadowing:
            String(localized: "Review the alias or function in your shell configuration. Keep it if intentional, or remove it there to run the executable from PATH.")
        }
    }
}

struct IssueResolution {
    let status: String?
    let symbol: String
    let tint: Color
    let reason: String
    let nextStep: String
}

extension HealthIssue {
    /// Explain the boundary between a safe App action and a user decision.
    func resolution(cleanupCandidate: CleanupCandidate?) -> IssueResolution {
        switch type {
        case .brokenSymlink, .brokenActiveExecutable:
            if cleanupCandidate != nil {
                return IssueResolution(
                    status: String(localized: "Ready to handle"), symbol: Symbol.good, tint: DS.Palette.success,
                    reason: String(localized: "CLI State confirmed this broken link can be moved to the Trash. It will check the link again and ask for confirmation first."),
                    nextStep: String(localized: "If you still need the original app, reinstall it instead of removing the link.")
                )
            }
            if type == .brokenActiveExecutable {
                return IssueResolution(
                    status: String(localized: "Needs repair"), symbol: Symbol.tools, tint: DS.Palette.warning,
                    reason: String(localized: "CLI State cannot confirm that this unavailable executable is a standalone broken link safe to remove."),
                    nextStep: String(localized: "Open the tool details and repair or reinstall it with the manager that owns this installation.")
                )
            }
            if type == .brokenSymlink, severity == .info {
                return IssueResolution(
                    status: String(localized: "System managed"), symbol: Symbol.systemManaged, tint: DS.Palette.textSecondary,
                    reason: String(localized: "This link is in a macOS-managed location. CLI State cannot remove it, and manual deletion is not recommended."),
                    nextStep: String(localized: "Leave the link in place; a macOS update or the component installer can repair it.")
                )
            }
            if let path = paths.first {
                let parent = (path as NSString).deletingLastPathComponent
                if !FileManager.default.isWritableFile(atPath: parent) {
                    return IssueResolution(
                        status: String(localized: "Administrator required"), symbol: Symbol.systemManaged, tint: DS.Palette.warning,
                        reason: String(localized: "Your account cannot write to \(parent), so CLI State cannot move this link to the Trash automatically."),
                        nextStep: String(localized: "If you need the original app, reinstall it. Otherwise, reveal the exact link in Finder and move it to the Trash with administrator authorization.")
                    )
                }
            }
            return IssueResolution(
                status: String(localized: "Recheck needed"), symbol: Symbol.refresh, tint: DS.Palette.textSecondary,
                reason: String(localized: "This link no longer matches an actionable cleanup candidate. It may have changed since the last scan."),
                nextStep: String(localized: "Check again before changing or removing it.")
            )

        case .missingPathEntry where severity == .info:
            return IssueResolution(
                status: String(localized: "System managed"), symbol: Symbol.systemManaged, tint: DS.Palette.textSecondary,
                reason: String(localized: "macOS can add this directory only while its component is mounted. Its absence does not require cleanup."),
                nextStep: String(localized: "Leave this system PATH entry unchanged.")
            )

        case .missingPathEntry, .duplicatePathEntry, .relativePathEntry, .shellShadowing:
            return IssueResolution(
                status: nil, symbol: Symbol.config, tint: DS.Palette.textSecondary,
                reason: String(localized: "PATH and shell aliases can come from several startup files or apps. CLI State cannot identify the exact source safely enough to edit it for you."),
                nextStep: handlingAdvice
            )

        case .pathConflict, .duplicateInstallation:
            return IssueResolution(
                status: nil, symbol: Symbol.tools, tint: DS.Palette.textSecondary,
                reason: String(localized: "Several installations may be intentional or needed by other projects. Removing one automatically could break those projects."),
                nextStep: handlingAdvice
            )

        case .runtimeEndOfLife where details["systemManaged"] == "true":
            return IssueResolution(
                status: String(localized: "System managed"), symbol: Symbol.systemManaged, tint: DS.Palette.textSecondary,
                reason: String(localized: "This runtime comes with macOS and cannot be upgraded or removed separately by CLI State."),
                nextStep: String(localized: "Install a supported runtime beside the system copy, then choose it for your projects through PATH or the project's version manager.")
            )

        default:
            return IssueResolution(
                status: nil, symbol: Symbol.info, tint: DS.Palette.textSecondary,
                reason: String(localized: "This issue needs a decision about your tools or environment before any change can be made safely."),
                nextStep: handlingAdvice
            )
        }
    }
}
