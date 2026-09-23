import CLIStateDomain
import Foundation
import Testing

@MainActor
private final class SchedulerModel: BackgroundCheckModel {
    var isScanning = false
    var isOperationRunning = false
    var preferences = UpdatePreferences(defaultPolicy: .automatic, checkHour: 0)
    var snapshot: EnvironmentSnapshot?
    var backgroundNotificationsEnabled = true
    var result: BackgroundCheckResult?
    var automaticAttempts: [Bool] = []

    func runBackgroundCheck(allowAutomaticInstalls: Bool) async -> BackgroundCheckResult? {
        automaticAttempts.append(allowAutomaticInstalls)
        return result
    }
}

@Suite("Background scheduler")
@MainActor
struct BackgroundSchedulerTests {
    private func result(completed: Bool = false, power: Bool = false, review: Bool = false) -> BackgroundCheckResult {
        BackgroundCheckResult(snapshot: nil, automaticUpdates: [], availableCount: 0,
                              needsReviewCount: review ? 1 : 0, skippedForPower: power,
                              didCompleteAutomaticPass: completed, reviewKeys: review ? ["review:php@9"] : [])
    }

    @Test func powerSkipAndScanFailureRetryOnTheSameDay() async throws {
        let name = "CLIState.scheduler-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SchedulerModel()
        let scheduler = BackgroundScheduler(model: model, defaults: defaults, postNotification: { _ in false })
        let now = Date()
        model.result = result(power: true)
        await scheduler.runIfDue(now: now)
        #expect(defaults.object(forKey: "LastBackgroundCheck") == nil)
        model.result = nil
        await scheduler.runIfDue(now: now)
        #expect(defaults.object(forKey: "LastBackgroundCheck") == nil)
        model.result = result(completed: true)
        await scheduler.runIfDue(now: now)
        #expect(defaults.object(forKey: "LastBackgroundCheck") as? Date == now)
        await scheduler.runIfDue(now: now)
        #expect(model.automaticAttempts == [true, true, true, false])
    }

    @Test func reviewOnlyUpdatesNotifyOncePerVersion() async throws {
        let name = "CLIState.scheduler-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SchedulerModel()
        model.result = result(review: true)
        var posted: [BackgroundCheckResult] = []
        let scheduler = BackgroundScheduler(model: model, defaults: defaults, postNotification: {
            posted.append($0)
            return true
        })
        await scheduler.runIfDue()
        await scheduler.runIfDue()
        #expect(posted.count == 1)
        #expect(posted.first?.needsReviewCount == 1)
        model.result?.reviewKeys = ["review:php@10"]
        await scheduler.runIfDue()
        #expect(posted.count == 2)
    }

    @Test func disabledOrFailedNotificationRemainsEligible() async throws {
        let name = "CLIState.scheduler-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SchedulerModel()
        model.result = result(review: true)
        model.backgroundNotificationsEnabled = false
        var attempts = 0
        let scheduler = BackgroundScheduler(model: model, defaults: defaults, postNotification: { _ in
            attempts += 1
            return attempts > 1
        })
        await scheduler.runIfDue()
        #expect(attempts == 0)
        model.backgroundNotificationsEnabled = true
        await scheduler.runIfDue()
        #expect(defaults.stringArray(forKey: "LastNotifiedUpdates") == nil)
        await scheduler.runIfDue()
        #expect(attempts == 2)
        #expect(defaults.stringArray(forKey: "LastNotifiedUpdates") == ["review:php@9"])
    }

    @Test func reviewNotificationHasContentAloneAndAlongsideAutomaticUpdates() throws {
        var report = result(review: true)
        let onlyReview = try #require(UpdateNotifier.content(for: report))
        #expect(!onlyReview.title.isEmpty)
        #expect(!onlyReview.body.isEmpty)
        report.automaticUpdates = [.init(name: "PHP", fromVersion: "8.5.7", toVersion: "8.5.10", succeeded: true)]
        let combined = try #require(UpdateNotifier.content(for: report))
        #expect(combined.body.contains("PHP"))
        #expect(combined.body.contains(onlyReview.title))
        #expect(UpdateNotifier.content(for: result()) == nil)
    }
}
