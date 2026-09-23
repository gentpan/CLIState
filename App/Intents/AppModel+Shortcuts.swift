import AppIntents
import CLIStateApplication
import CLIStateDomain
import Foundation

enum ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case scanFailed
    case toolNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .scanFailed: LocalizedStringResource("CLI State couldn't scan your environment. Open CLI State for details.", table: "MenuBar")
        case .toolNotFound: LocalizedStringResource("This tool isn't in the latest scan. Scan again, then try again.", table: "MenuBar")
        }
    }
}

extension LocalizedStringResource {
    /// Text that is already localized, or never translated (names, paths, versions).
    static func verbatim(_ text: String) -> LocalizedStringResource {
        LocalizedStringResource("\(text)", table: "MenuBar")
    }
}

/// Scans for Shortcuts through the same `AppModel` as the window and menu bar,
/// so an intent never starts a second pipeline next to a running scan.
extension AppModel {
    private static let shortcutPollInterval: Duration = .milliseconds(100)

    /// A snapshot from a scan of at least `depth` that finished after this call.
    /// Joins a scan already in progress instead of queuing another one.
    func scanForShortcut(_ depth: ScanDepth) async throws -> EnvironmentSnapshot {
        startIfNeeded()
        // After a background launch, let the launch pass begin its own scans (it
        // also checks for updates) rather than racing it.
        while !isLaunchPassFinished, !isScanning {
            try await Task.sleep(for: Self.shortcutPollInterval)
        }
        var observed: ScanDepth?
        while case let .scanning(current) = scanState {
            if observed != .deep { observed = current }
            try await Task.sleep(for: Self.shortcutPollInterval)
        }
        if let observed, scanState != .failed, let snapshot, depth == .fast || observed == .deep {
            return snapshot
        }

        switch depth {
        case .fast: await refresh()
        case .deep: await checkForUpdates()
        }
        // `refresh()` returns at once if another scan started first; wait for that one.
        while isScanning {
            try await Task.sleep(for: Self.shortcutPollInterval)
        }
        guard scanState != .failed, let snapshot else { throw ShortcutError.scanFailed }
        return snapshot
    }

    /// The latest snapshot without scanning, once the cache or first scan is loaded.
    func snapshotForShortcut() async throws -> EnvironmentSnapshot {
        startIfNeeded()
        while snapshot == nil {
            if isLaunchPassFinished { throw ShortcutError.scanFailed }
            try await Task.sleep(for: Self.shortcutPollInterval)
        }
        guard let snapshot else { throw ShortcutError.scanFailed }
        return snapshot
    }

    /// Updates and issues as the UI counts them: Scanning settings and skipped
    /// versions applied. Shared by the menu bar extra and Shortcuts.
    var environmentDigest: EnvironmentDigest {
        EnvironmentDigest(tools: visibleTools, issues: issues, skippedVersions: preferences.skippedVersions)
    }
}
