import CLIStateDomain
import Foundation
import UserNotifications

/// Minimal model surface so scheduling can be tested without launching the app.
@MainActor
protocol BackgroundCheckModel: AnyObject {
    var isScanning: Bool { get }
    var isOperationRunning: Bool { get }
    var preferences: UpdatePreferences { get }
    var snapshot: EnvironmentSnapshot? { get }
    var backgroundNotificationsEnabled: Bool { get }
    func runBackgroundCheck(allowAutomaticInstalls: Bool) async -> BackgroundCheckResult?
}

/// Runs background checks (§162, §163) while the app is open: package info is
/// refreshed and updates checked every `checkInterval`; tools set to automatic
/// are installed at most once a day, after `checkHour`.
@MainActor
final class BackgroundScheduler {
    private weak var model: (any BackgroundCheckModel)?
    private let defaults: UserDefaults
    private let postNotification: @MainActor (BackgroundCheckResult) async -> Bool
    private var loop: Task<Void, Never>?
    /// Last day automatic installs were attempted (key kept from the daily-only scheduler).
    private static let lastRunKey = "LastBackgroundCheck"
    private static let notifiedKey = "LastNotifiedUpdates"
    /// How often the scheduler wakes up to see whether a check is due.
    private static let pollInterval: Duration = .seconds(10 * 60)

    init(model: any BackgroundCheckModel, defaults: UserDefaults = .standard, postNotification: @escaping @MainActor (BackgroundCheckResult) async -> Bool = { await UpdateNotifier.post($0) }) {
        self.model = model
        self.defaults = defaults
        self.postNotification = postNotification
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runIfDue()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func runIfDue(now: Date = .now) async {
        guard let model, !model.isScanning, !model.isOperationRunning,
              model.preferences.defaultPolicy != .off || model.preferences.hasAnyOptIn
        else { return }
        let calendar = Calendar.current
        let preferences = model.preferences
        let installedToday = (defaults.object(forKey: Self.lastRunKey) as? Date).map { calendar.isDate($0, inSameDayAs: now) } ?? false
        let installDue = calendar.component(.hour, from: now) >= preferences.checkHour && !installedToday
        let checkDue = LatestVersionFreshness.needsDeepCheck(model.snapshot, now: now, window: preferences.checkInterval.seconds)
        guard installDue || checkDue else { return }

        guard let result = await model.runBackgroundCheck(allowAutomaticInstalls: installDue) else { return }
        if installDue, result.didCompleteAutomaticPass { defaults.set(now, forKey: Self.lastRunKey) }

        // Checks run every few hours; only versions not announced before are news.
        let announced = Set(defaults.stringArray(forKey: Self.notifiedKey) ?? [])
        let keys = result.availableKeys + result.reviewKeys
        let hasNewVersions = !Set(keys).subtracting(announced).isEmpty
        guard model.backgroundNotificationsEnabled, hasNewVersions || !result.automaticUpdates.isEmpty else { return }
        if await postNotification(result) {
            defaults.set(keys, forKey: Self.notifiedKey)
        }
    }
}

extension UpdatePreferences {
    /// A tool or provider override can opt in even when the default is off.
    var hasAnyOptIn: Bool {
        toolPolicies.values.contains { $0 != .off } || providerPolicies.values.contains { $0 != .off }
    }
}

/// Posts one summary notification per background run, never one per patch (§57).
enum UpdateNotifier {
    static func content(for result: BackgroundCheckResult) -> UNMutableNotificationContent? {
        let succeeded = result.automaticUpdates.filter(\.succeeded)
        let failed = result.automaticUpdates.count - succeeded.count
        let content = UNMutableNotificationContent()

        if !result.automaticUpdates.isEmpty {
            content.title = String(localized: "Updated \(succeeded.count) tools automatically")
            var lines = succeeded.map { update in
                "\(update.name) \(update.fromVersion ?? "?") → \(update.toVersion ?? "?")"
            }
            if failed > 0 { lines.append(String(localized: "\(failed) updates failed. Open CLI State for details.")) }
            content.body = lines.joined(separator: "\n")
        } else if result.availableCount > 0 {
            content.title = String(localized: "\(result.availableCount) CLI updates available")
            content.body = result.skippedForPower
                ? String(localized: "Automatic updates wait until your Mac is connected to power.")
                : String(localized: "Open CLI State to review and update.")
        } else if result.needsReviewCount > 0 {
            content.title = String(localized: "\(result.needsReviewCount) updates need your review")
            content.body = String(localized: "Open CLI State to review updates that couldn't run automatically.")
        } else {
            return nil
        }
        if result.needsReviewCount > 0, result.availableCount > 0 || !result.automaticUpdates.isEmpty {
            content.body += "\n" + String(localized: "\(result.needsReviewCount) updates need your review")
        }

        return content
    }

    static func post(_ result: BackgroundCheckResult) async -> Bool {
        guard let content = content(for: result) else { return false }
        let center = UNUserNotificationCenter.current()
        // Permission is requested only when there is something to say (§167).
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return false }
        let request = UNNotificationRequest(identifier: "clistate.background-check", content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
