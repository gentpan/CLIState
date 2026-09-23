import CLIStateDomain
import Foundation

/// What a background pass did, for the model and the notification.
struct BackgroundCheckResult: Sendable {
    struct Update: Hashable, Sendable {
        var name: String
        var fromVersion: String?
        var toVersion: String?
        var succeeded: Bool
    }

    var snapshot: EnvironmentSnapshot?
    var automaticUpdates: [Update]
    /// Updates the user chose to hear about but not install automatically.
    var availableCount: Int
    /// `installation@latest` for each of those, so repeated checks notify only about new versions.
    var availableKeys: [String] = []
    /// Automatic updates held back because they are major or unknown.
    var needsReviewCount: Int
    var skippedForPower: Bool
    var didCompleteAutomaticPass: Bool = false
    var reviewKeys: [String] = []
}
