import CLIStateDomain
import SwiftUI

// Domain types carry no display strings; this file turns enums into localized text.

extension ProviderID {
    var displayName: String {
        switch self {
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .uv: "uv"
        case .pnpm: "pnpm"
        case .pipx: "pipx"
        case .cargo: "Cargo"
        case .bun: "Bun"
        case .go: "Go"
        case .rustup: "rustup"
        case .nvm: "nvm"
        case .fnm: "fnm"
        case .volta: "Volta"
        case .mise: "mise"
        case .asdf: "asdf"
        case .pyenv: "pyenv"
        case .rbenv: "rbenv"
        case .native: String(localized: "Native Installer")
        case .appBundle: String(localized: "App Bundle")
        case .system: String(localized: "macOS")
        case .standalone: String(localized: "Standalone")
        default: rawValue
        }
    }

    /// Providers CLIState can run write operations through in 1.0.
    var supportsUpdates: Bool { [.homebrew, .npm, .uv, .native].contains(self) }
}

extension AttributionConfidence {
    var title: String {
        switch self {
        case .confirmed: String(localized: "Confirmed")
        case .probable: String(localized: "Probable")
        case .unknown: String(localized: "Unknown")
        }
    }

    var symbol: String {
        switch self {
        case .confirmed: Symbol.evidence
        case .probable: Symbol.info
        case .unknown: Symbol.unknown
        }
    }

    var tint: Color {
        switch self {
        case .confirmed: DS.Palette.success
        case .probable: DS.Palette.textSecondary
        case .unknown: DS.Palette.textTertiary
        }
    }
}

extension ToolCategory {
    var title: String {
        switch self {
        case .runtime: String(localized: "Runtime")
        case .aiCLI: String(localized: "AI CLI")
        case .developerTool: String(localized: "Developer Tool")
        case .database: String(localized: "Database")
        case .packageManager: String(localized: "Package Manager")
        case .dependency: String(localized: "Dependency")
        case .unrecognized: String(localized: "Unrecognized")
        }
    }

    var pluralTitle: String {
        switch self {
        case .runtime: String(localized: "Runtimes")
        case .aiCLI: String(localized: "AI CLI")
        case .developerTool: String(localized: "Developer Tools")
        case .database: String(localized: "Databases")
        case .packageManager: String(localized: "Package Managers")
        case .dependency: String(localized: "Dependencies")
        case .unrecognized: String(localized: "Unrecognized")
        }
    }
}

extension LinkState {
    var statusKind: StatusKind {
        switch self {
        case .active: .active
        case .shadowed: .shadowed
        case .notOnPath: .notLinked
        case .broken: .needsAttention
        }
    }
}

extension ServiceStatus {
    var title: String {
        switch self {
        case .running: StatusKind.running.title
        case .stopped: StatusKind.stopped.title
        case .scheduled: String(localized: "Scheduled")
        case .error: StatusKind.needsAttention.title
        case .unknown: StatusKind.unknown.title
        }
    }

    var symbol: String {
        switch self {
        case .running: Symbol.running
        case .stopped: Symbol.stopped
        case .scheduled: Symbol.history
        case .error: Symbol.needsAttention
        case .unknown: Symbol.unknown
        }
    }

    var tint: Color {
        switch self {
        case .running: DS.Palette.success
        case .stopped, .scheduled: DS.Palette.textSecondary
        case .error: DS.Palette.warning
        case .unknown: DS.Palette.textTertiary
        }
    }
}

extension HealthSeverity {
    var title: String {
        switch self {
        case .critical: String(localized: "Critical")
        case .warning: String(localized: "Warning")
        case .info: String(localized: "Info")
        }
    }

    var sectionTitle: String {
        switch self {
        case .critical: String(localized: "Critical")
        case .warning: String(localized: "Warnings")
        case .info: String(localized: "Suggestions")
        }
    }

    var symbol: String {
        switch self {
        case .critical: Symbol.failed
        case .warning: Symbol.needsAttention
        case .info: Symbol.info
        }
    }

    var tint: Color {
        switch self {
        case .critical: DS.Palette.error
        case .warning: DS.Palette.warning
        case .info: DS.Palette.textSecondary
        }
    }
}

extension EnvironmentHealth {
    var title: String {
        switch self {
        case .good: String(localized: "Good")
        case .attention: String(localized: "Attention")
        case .issuesFound: String(localized: "Issues Found")
        }
    }

    var summary: String {
        switch self {
        case .good: String(localized: "Your command-line environment looks consistent.")
        case .attention: String(localized: "A few things may not behave the way you expect.")
        case .issuesFound: String(localized: "Some commands are broken or can't be found.")
        }
    }

    var symbol: String {
        switch self {
        case .good: Symbol.good
        case .attention: Symbol.needsAttention
        case .issuesFound: Symbol.failed
        }
    }

    var tint: Color {
        switch self {
        case .good: DS.Palette.success
        case .attention: DS.Palette.warning
        case .issuesFound: DS.Palette.error
        }
    }
}

extension PATHEntryStatus {
    var title: String {
        switch self {
        case .ok: String(localized: "Found")
        case .missing: String(localized: "Missing")
        case .notDirectory: String(localized: "Not a Directory")
        case .duplicate: String(localized: "Duplicate")
        case .relative: String(localized: "Relative")
        case .empty: String(localized: "Empty")
        case .protectedLocation: String(localized: "Protected Location")
        case .unreadable: String(localized: "Unreadable")
        }
    }

    var symbol: String {
        switch self {
        case .ok: Symbol.latest
        case .missing, .notDirectory, .unreadable: Symbol.needsAttention
        case .duplicate: "square.on.square"
        case .relative, .empty: Symbol.info
        case .protectedLocation: Symbol.systemManaged
        }
    }

    var tint: Color {
        switch self {
        case .ok: DS.Palette.success
        case .missing, .notDirectory, .unreadable: DS.Palette.warning
        case .duplicate, .relative, .empty, .protectedLocation: DS.Palette.textSecondary
        }
    }
}

extension PATHSource {
    var title: String {
        switch self {
        case .homebrew: "Homebrew"
        case .system: String(localized: "macOS")
        case .userLocal: String(localized: "User")
        case .cargo: "Cargo"
        case .go: "Go"
        case .bun: "Bun"
        case .npm: "npm"
        case .versionManager: String(localized: "Version Manager")
        case .application: String(localized: "Application")
        case .unknown: String(localized: "Unknown")
        }
    }
}

extension CPUArchitecture {
    var title: String {
        switch self {
        case .arm64: "arm64"
        case .x86_64: "x86_64"
        case .universal: String(localized: "Universal")
        case .script: String(localized: "Script")
        case .unknown: String(localized: "Unknown")
        }
    }
}

extension UpdateKind {
    var title: String {
        switch self {
        case .patch: String(localized: "Patch")
        case .minor: String(localized: "Minor")
        case .major: String(localized: "Major")
        case .unknown: String(localized: "Other")
        }
    }

    var tint: Color {
        switch self {
        case .major: DS.Palette.warning
        case .patch, .minor, .unknown: DS.Palette.textSecondary
        }
    }
}

extension AutoUpdatePolicy {
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .notify: String(localized: "Notify")
        case .automatic: String(localized: "Automatic")
        }
    }

    var explanation: String {
        switch self {
        case .off: String(localized: "Don't check this in the background.")
        case .notify: String(localized: "Check in the background and notify you. Nothing is installed.")
        case .automatic: String(localized: "Install matching updates in the background, then notify you.")
        }
    }
}

extension AutoUpdateScope {
    var title: String {
        switch self {
        case .patchAndMinor: String(localized: "Patch and minor updates only")
        case .all: String(localized: "All updates, including major versions")
        }
    }
}

extension UpdateCheckInterval {
    var title: String {
        switch self {
        case .hourly: String(localized: "Every hour")
        case .every3Hours: String(localized: "Every 3 hours")
        case .every6Hours: String(localized: "Every 6 hours")
        case .daily: String(localized: "Once a day")
        }
    }
}

extension CleanupKind {
    var symbol: String {
        switch self {
        case .providerCache: "internaldrive"
        case .oldVersions: Symbol.history
        case .orphanedDependencies: "puzzlepiece"
        case .brokenSymlink: "link.badge.plus"
        case .unusedRuntime: Symbol.runtimes
        case .leftovers: Symbol.cleanup
        }
    }

    func title(provider: ProviderID?) -> String {
        let name = provider?.displayName ?? ""
        return switch self {
        case .providerCache: String(localized: "\(name) download cache")
        case .oldVersions: String(localized: "Old \(name) versions and cache")
        case .orphanedDependencies: String(localized: "Unused \(name) dependencies")
        case .brokenSymlink: String(localized: "Broken links in PATH")
        case .unusedRuntime: String(localized: "Unused runtime")
        case .leftovers: String(localized: "Leftover files", table: "Tools")
        }
    }

    var explanation: String {
        switch self {
        case .providerCache: String(localized: "Downloaded package archives. They are fetched again when needed.")
        case .oldVersions: String(localized: "Previous versions kept after upgrades, plus cached downloads.")
        case .orphanedDependencies: String(localized: "Packages installed as dependencies that nothing needs anymore.")
        case .brokenSymlink: String(localized: "Links that point to files that no longer exist. They are moved to the Trash, so you can restore them.")
        case .unusedRuntime: String(localized: "Installed, but not in PATH and not used by other packages. If you no longer need it, uninstall it from the tool's details.")
        case .leftovers: String(localized: "Caches, logs and settings a tool left in your home folder. They are moved to the Trash.", table: "Tools")
        }
    }
}

extension CleanupRisk {
    var title: String {
        switch self {
        case .low: String(localized: "Low Risk")
        case .medium: String(localized: "Review First")
        }
    }

    var symbol: String {
        switch self {
        case .low: Symbol.latest
        case .medium: Symbol.needsAttention
        }
    }

    var tint: Color {
        switch self {
        case .low: DS.Palette.success
        case .medium: DS.Palette.warning
        }
    }
}

extension PreflightOutcome {
    var title: String {
        switch self {
        case .passed: String(localized: "Passed")
        case .warning: String(localized: "Warning")
        case .failed: String(localized: "Failed")
        case .info: String(localized: "Note")
        }
    }

    var symbol: String {
        switch self {
        case .passed: Symbol.latest
        case .warning: Symbol.needsAttention
        case .failed: Symbol.failed
        case .info: Symbol.info
        }
    }

    var tint: Color {
        switch self {
        case .passed: DS.Palette.success
        case .warning: DS.Palette.warning
        case .failed: DS.Palette.error
        case .info: DS.Palette.textSecondary
        }
    }
}

extension PreflightKind {
    /// Wording depends on the outcome so a check never claims the opposite of its result.
    func title(provider: ProviderID, outcome: PreflightOutcome) -> String {
        let name = provider.displayName
        let ok = outcome == .passed
        return switch self {
        case .providerAvailable: ok || outcome == .info ? String(localized: "\(name) is available") : String(localized: "\(name) isn't available")
        case .providerUnchanged: ok ? String(localized: "\(name) hasn't changed since the last scan") : String(localized: "\(name) changed since the last scan")
        case .installationPresent: outcome == .failed ? String(localized: "Installation is missing") : String(localized: "Installation is still present")
        case .ownershipConfirmed:
            switch outcome {
            case .passed: String(localized: "Ownership is confirmed")
            case .info: String(localized: "No package manager owns this")
            case .warning, .failed: String(localized: "Ownership isn't confirmed")
            }
        case .writableLocation: outcome == .failed ? String(localized: "Install location isn't writable") : String(localized: "Install location is writable")
        case .networkRequired: String(localized: "Requires a network connection")
        case .dryRun: String(localized: "Dry run")
        case .packageNameValid: outcome == .failed ? String(localized: "Package name isn't valid") : String(localized: "Package name is valid")
        case .reverseDependencies: ok ? String(localized: "Nothing else depends on this") : String(localized: "Other packages depend on this")
        case .systemManaged: ok ? String(localized: "Not managed by macOS") : String(localized: "Managed by macOS")
        case .userData: ok ? String(localized: "No settings or history selected", table: "Tools") : String(localized: "Includes your settings or history", table: "Tools")
        }
    }
}

extension PreflightItem.Change {
    var groupTitle: String {
        switch self {
        case .install: String(localized: "Will install")
        case .upgrade: String(localized: "Will upgrade dependencies")
        case .upgradeDependent: String(localized: "Will upgrade dependents")
        case .remove: String(localized: "Will remove")
        case .dependent: String(localized: "Depends on it")
        case .reclaim: String(localized: "Will free space from")
        }
    }
}

extension CommandHistoryEntry.Status {
    var title: String {
        switch self {
        case .running: String(localized: "Running")
        case .succeeded: String(localized: "Succeeded")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        case .unverified: String(localized: "Not Verified")
        case .interrupted: String(localized: "Interrupted")
        }
    }

    var symbol: String {
        switch self {
        case .running: Symbol.running
        case .succeeded: Symbol.latest
        case .failed: Symbol.failed
        case .cancelled: Symbol.cancelled
        case .unverified, .interrupted: Symbol.needsAttention
        }
    }

    var tint: Color {
        switch self {
        case .running: DS.Palette.highlight
        case .succeeded: DS.Palette.success
        case .failed: DS.Palette.error
        case .cancelled: DS.Palette.textSecondary
        case .unverified, .interrupted: DS.Palette.warning
        }
    }
}

extension OperationTrigger {
    var title: String {
        switch self {
        case .user: String(localized: "You")
        case .automaticPolicy: String(localized: "Automatic")
        }
    }

    var symbol: String {
        switch self {
        case .user: "person"
        case .automaticPolicy: Symbol.automatic
        }
    }
}

extension ShellShadow.Kind {
    var title: String {
        switch self {
        case .alias: String(localized: "Alias")
        case .function: String(localized: "Function")
        case .builtin: String(localized: "Shell builtin")
        case .reserved: String(localized: "Reserved word")
        case .hashed: String(localized: "Hashed path")
        }
    }
}

extension AttributionEvidence {
    var text: String {
        switch self {
        case let .inventoryContains(provider, package):
            String(localized: "\(provider.displayName) lists the package \(package)")
        case let .symlinkResolvesInto(path):
            String(localized: "Link resolves into \(path)")
        case let .knownLayout(path):
            String(localized: "Matches the known install layout \(path)")
        case let .versionMatches(version):
            String(localized: "Reported version matches \(version)")
        case let .pathDirectory(path):
            String(localized: "Located in \(path) (weak evidence)")
        case let .systemLocation(path):
            String(localized: "Located in the system directory \(path)")
        }
    }

    var isWeak: Bool {
        if case .pathDirectory = self { return true }
        return false
    }
}

extension ServiceAction {
    /// "Start PostgreSQL 17"
    func title(for name: String) -> String {
        switch self {
        case .start: String(localized: "Start \(name)")
        case .stop: String(localized: "Stop \(name)")
        case .restart: String(localized: "Restart \(name)")
        }
    }

    var title: String {
        switch self {
        case .start: String(localized: "Start")
        case .stop: String(localized: "Stop")
        case .restart: String(localized: "Restart")
        }
    }

    var symbol: String {
        switch self {
        case .start: Symbol.start
        case .stop: Symbol.stop
        case .restart: Symbol.restart
        }
    }
}
