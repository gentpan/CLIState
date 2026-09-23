import Foundation
import Observation
import Sparkle

/// CLI State's own updates through Sparkle (§164), separate from CLI tool updates.
/// Stays inert until a feed (`SUFeedURL` or `CLIStateUpdateServerFeedURL`) and
/// `SUPublicEDKey` are set in Info.plist, so an unconfigured build never contacts anything.
@Observable
@MainActor
final class AppUpdater {
    let isConfigured: Bool
    private(set) var canCheckForUpdates = false
    private(set) var source: AppUpdateSource
    private let controller: SPUStandardUpdaterController?
    /// Sparkle keeps its delegate weakly.
    private let feeds: UpdateFeedSelector
    private var observation: NSKeyValueObservation?

    init(bundle: Bundle = .main) {
        feeds = UpdateFeedSelector(bundle: bundle)
        source = feeds.source
        let key = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        isConfigured = feeds.currentFeed != nil && !key.isEmpty

        guard isConfigured else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: feeds, userDriverDelegate: nil)
        self.controller = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        Task { [feeds] in await feeds.probe() }
        // Sparkle changes `canCheckForUpdates` on the main thread.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            MainActor.assumeIsolated { self?.canCheckForUpdates = value }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Whether this build lists an update server besides GitHub.
    var hasUpdateServer: Bool { feeds.hasServer }

    func setSource(_ newValue: AppUpdateSource) {
        feeds.source = newValue
        source = newValue
    }

    /// Checks which host answers first, so a user without GitHub access isn't shown
    /// a download error.
    func checkForUpdates() {
        Task {
            await feeds.probe()
            controller?.checkForUpdates(nil)
        }
    }
}
