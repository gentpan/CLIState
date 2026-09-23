import CLIStateDomain
import Foundation
import IOKit.ps

/// Decides what the background run may do under the user's `UpdatePreferences`.
/// Pure so it can be tested without scheduling anything.
public struct AutoUpdatePlanner: Sendable {
    public struct Decision: Hashable, Sendable {
        /// Installations to update without asking, grouped per provider plan.
        public var automatic: [InstallationID]
        /// Updates to surface in a notification only.
        public var notify: [InstallationID]
        /// Skipped because they need review (major/unknown) under `.patchAndMinor`.
        public var needsReview: [InstallationID]
    }

    public init() {}

    public func decide(snapshot: EnvironmentSnapshot, preferences: UpdatePreferences) -> Decision {
        var decision = Decision(automatic: [], notify: [], needsReview: [])
        for tool in snapshot.tools {
            for installation in tool.installations where installation.hasUpdate {
                if let latest = installation.latest?.value.rawValue, preferences.skippedVersions[installation.id] == latest { continue }
                switch preferences.policy(for: tool.id, provider: installation.ownership.provider) {
                case .off:
                    continue
                case .notify:
                    decision.notify.append(installation.id)
                case .automatic:
                    if preferences.allowsAutomaticInstall(tool: tool.id, installation: installation) {
                        decision.automatic.append(installation.id)
                    } else {
                        decision.needsReview.append(installation.id)
                    }
                }
            }
        }
        decision.automatic.sort()
        decision.notify.sort()
        decision.needsReview.sort()
        return decision
    }
}

public protocol PowerSourceMonitoring: Sendable {
    var isOnACPower: Bool { get }
}

public struct SystemPowerSource: PowerSourceMonitoring {
    public init() {}

    public var isOnACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return true }
        return (type as String) == kIOPSACPowerValue
    }
}

/// One background pass: deep scan, then run allowed updates through the normal
/// operation workflow (preflight included; blocked plans are skipped, never forced).
public actor AutoUpdateRunner {
    public struct Report: Hashable, Sendable {
        public var updated: [OperationOutcome]
        public var skippedBlocked: [InstallationID]
        public var notify: [InstallationID]
        public var needsReview: [InstallationID]
        public var skippedForPower: Bool
        /// Metadata refreshes that ran first, e.g. `brew update`.
        public var metadataRefreshes: [OperationOutcome] = []
        public var scanCompleted: Bool = false
        /// A daily pass reached a decision; power or scan failures leave it retryable.
        public var didCompleteAutomaticPass: Bool = false
    }

    /// Every check refreshes package info first (user decision); this only stops
    /// repeated clicks or back-to-back checks from running `brew update` twice.
    public static let metadataRefreshInterval: TimeInterval = 10 * 60

    private let scan: ScanCoordinator
    private let operations: OperationCoordinator
    private let power: any PowerSourceMonitoring
    private let history: (any CommandHistoryRepository)?
    private let clock: @Sendable () -> Date
    private let planner = AutoUpdatePlanner()

    /// - Parameter history: finds earlier metadata refreshes (automatic or from the
    ///   Refresh Package Info button); without it every run refreshes.
    public init(
        scan: ScanCoordinator,
        operations: OperationCoordinator,
        power: any PowerSourceMonitoring = SystemPowerSource(),
        history: (any CommandHistoryRepository)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scan = scan
        self.operations = operations
        self.power = power
        self.history = history
        self.clock = clock
    }

    /// - Parameter allowAutomaticInstalls: `false` for the periodic checks between the
    ///   daily install window; automatic candidates are then only reported.
    public func run(preferences: UpdatePreferences, allowAutomaticInstalls: Bool = true) async -> Report {
        var report = Report(updated: [], skippedBlocked: [], notify: [], needsReview: [], skippedForPower: false)
        if preferences.refreshMetadataBeforeCheck {
            report.metadataRefreshes = await refreshStaleMetadata()
        }
        guard let snapshot = await scan.scan(depth: .deep) else { return report }
        report.scanCompleted = true
        let decision = planner.decide(snapshot: snapshot, preferences: preferences)
        report.notify = decision.notify
        report.needsReview = decision.needsReview

        guard !decision.automatic.isEmpty else {
            report.didCompleteAutomaticPass = allowAutomaticInstalls
            return report
        }
        guard allowAutomaticInstalls else {
            report.notify += decision.automatic
            return report
        }
        if preferences.requiresACPower, !power.isOnACPower {
            report.skippedForPower = true
            report.notify += decision.automatic
            return report
        }

        guard let prepared = try? await operations.prepareUpdateAll(decision.automatic, trigger: .automaticPolicy) else { return report }
        report.didCompleteAutomaticPass = true
        for operation in prepared {
            if operation.isBlocked {
                report.skippedBlocked += operation.plan.targets.compactMap(\.installationID)
                continue
            }
            for await progress in await operations.execute(operation) {
                if case let .finished(outcome) = progress { report.updated.append(outcome) }
            }
        }
        return report
    }

    /// Runs each provider's metadata refresh through the normal operation workflow,
    /// so it is serialized with other mutations and recorded in history. A failure
    /// (e.g. offline) never stops the check; it just leaves the old metadata.
    public func refreshStaleMetadata(olderThan interval: TimeInterval = metadataRefreshInterval, trigger: OperationTrigger = .automaticPolicy) async -> [OperationOutcome] {
        if await scan.discoveryResult == nil {
            await scan.scan(depth: .fast)
        }
        let recent = await recentlyRefreshedProviders(within: interval)
        var outcomes: [OperationOutcome] = []
        for providerID in await scan.metadataRefreshProviderIDs where !recent.contains(providerID) {
            guard let prepared = try? await operations.prepare(.refreshMetadata(providerID), trigger: trigger),
                  !prepared.isBlocked
            else { continue }
            for await progress in await operations.execute(prepared) {
                if case let .finished(outcome) = progress { outcomes.append(outcome) }
            }
        }
        return outcomes
    }

    /// Providers whose package data is younger than `interval`: refreshed through
    /// CLIState (history) or by any `brew update`, as the provider last observed it.
    private func recentlyRefreshedProviders(within interval: TimeInterval) async -> Set<ProviderID> {
        let now = clock()
        func isRecent(_ date: Date) -> Bool {
            let age = now.timeIntervalSince(date)
            return age >= 0 && age < interval
        }
        var recent = Set((await scan.snapshot?.providers ?? []).filter { $0.metadataUpdatedAt.map(isRecent) ?? false }.map(\.providerID))
        if let entries = try? await history?.entries(limit: 200) {
            recent.formUnion(entries.lazy
                .filter { $0.planKind == .refreshMetadata && $0.status == .succeeded }
                .filter { isRecent($0.finishedAt ?? $0.startedAt) }
                .map(\.providerID))
        }
        return recent
    }
}
