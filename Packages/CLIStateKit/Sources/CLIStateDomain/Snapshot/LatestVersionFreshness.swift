import Foundation

/// Decides whether latest-version data is recent enough to reuse. Launches reuse a
/// recent deep check instead of hitting the network again (`brew outdated`, `npm
/// outdated`, dist-tags…); the daily background check and "Check for Updates" still
/// run real deep scans.
public enum LatestVersionFreshness {
    public static let defaultWindow: TimeInterval = 6 * 60 * 60

    /// Snapshots saved before `latestCheckedAt` existed count as never checked: one
    /// extra deep scan after upgrading, instead of trusting a deep scan that may have failed.
    public static func needsDeepCheck(_ snapshot: EnvironmentSnapshot?, now: Date, window: TimeInterval = defaultWindow) -> Bool {
        guard let checked = snapshot?.latestCheckedAt else { return true }
        let age = now.timeIntervalSince(checked)
        // A check "in the future" means the clock moved back; don't trust it.
        return age < 0 || age >= window
    }
}
