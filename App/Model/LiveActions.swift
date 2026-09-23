import CLIStateApplication
import CLIStateDomain
import Foundation

enum LiveActionsError: LocalizedError {
    case scanFailed
    case metadataRefreshFailed

    var errorDescription: String? {
        switch self {
        case .scanFailed: String(localized: "The environment scan didn't finish. Try again.")
        case .metadataRefreshFailed: String(localized: "Package information could not be refreshed. Check your connection and try again before updating.")
        }
    }
}

/// `AppActions` backed by the real Application layer. All process execution
/// happens inside `AppEnvironment`'s coordinators; this type only translates
/// between their types and the UI's.
@MainActor
final class LiveActions: AppActions {
    /// Internal so feature extensions (environment restore) can reach the coordinators.
    let environment: AppEnvironment
    private let preferencesStore: UpdatePreferencesStore
    private var preferences: UpdatePreferences

    init(environment: AppEnvironment, defaults: UserDefaults = .standard) {
        self.environment = environment
        preferencesStore = UpdatePreferencesStore(defaults: defaults)
        // Unreadable preferences load as defaults and stay on disk until the user changes a setting.
        preferences = preferencesStore.load().preferences
    }

    // MARK: Scanning

    func loadCachedSnapshot() async -> EnvironmentSnapshot? {
        await environment.scan.loadCached()
    }

    func refresh() async throws -> EnvironmentSnapshot {
        guard let snapshot = await environment.scan.scan(depth: .fast) else { throw LiveActionsError.scanFailed }
        return snapshot
    }

    func checkForUpdates() async throws -> EnvironmentSnapshot {
        // `brew outdated` only compares against Homebrew's local index, so without this a
        // version released since the last `brew update` wouldn't show up.
        if preferences.refreshMetadataBeforeCheck {
            _ = await environment.autoUpdate.refreshStaleMetadata(trigger: .user)
        }
        guard let snapshot = await environment.scan.scan(depth: .deep) else { throw LiveActionsError.scanFailed }
        return snapshot
    }

    func forceCheckForUpdates() async throws -> EnvironmentSnapshot {
        if await environment.scan.discoveryResult == nil {
            guard await environment.scan.scan(depth: .fast) != nil else { throw LiveActionsError.scanFailed }
        }
        for provider in await environment.scan.metadataRefreshProviderIDs {
            let prepared = try await environment.operations.prepare(.refreshMetadata(provider), trigger: .user)
            guard !prepared.isBlocked else { throw LiveActionsError.metadataRefreshFailed }
            var succeeded = false
            for await progress in await environment.operations.execute(prepared) {
                if case let .finished(outcome) = progress { succeeded = outcome.status == .succeeded }
            }
            guard succeeded else { throw LiveActionsError.metadataRefreshFailed }
        }
        guard let snapshot = await environment.scan.scan(depth: .deep) else { throw LiveActionsError.scanFailed }
        return snapshot
    }

    func refreshCleanupCandidates() async -> EnvironmentSnapshot? {
        _ = await environment.scan.refreshCleanupCandidates()
        return await environment.scan.snapshot
    }

    func runBackgroundCheck(preferences: UpdatePreferences, allowAutomaticInstalls: Bool) async -> BackgroundCheckResult? {
        let report = await environment.autoUpdate.run(preferences: preferences, allowAutomaticInstalls: allowAutomaticInstalls)
        let snapshot = await environment.scan.snapshot
        guard report.scanCompleted else { return nil }
        let updates = report.updated.flatMap { outcome in
            outcome.plan.targets.map { target in
                BackgroundCheckResult.Update(
                    name: target.displayName,
                    fromVersion: target.fromVersion,
                    toVersion: target.installationID.flatMap { outcome.verifiedVersions[$0] } ?? target.toVersion,
                    succeeded: outcome.status == .succeeded
                )
            }
        }
        return BackgroundCheckResult(
            snapshot: snapshot,
            automaticUpdates: updates,
            availableCount: report.notify.count,
            availableKeys: report.notify.map { id in "\(id.rawValue)@\(snapshot?.tools.lazy.compactMap({ $0.installation(id) }).first?.latest?.value.rawValue ?? "")" },
            needsReviewCount: report.needsReview.count + report.skippedBlocked.count,
            skippedForPower: report.skippedForPower,
            didCompleteAutomaticPass: report.didCompleteAutomaticPass,
            reviewKeys: (report.needsReview + report.skippedBlocked).map { id in
                "review:\(id.rawValue)@\(snapshot?.tools.lazy.compactMap({ $0.installation(id) }).first?.latest?.value.rawValue ?? "")"
            }
        )
    }

    func exportDiagnostics(to url: URL) async throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let exporter = DiagnosticsExporter(context: .current(appVersion: version, build: build))
        let history = (try? await environment.history.entries(limit: 50)) ?? []
        let snapshot = await environment.scan.snapshot
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("clistate-diagnostics", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        try exporter.write(snapshot: snapshot, history: history, to: staging)
        try await DiagnosticsExporter.zip(directory: staging, to: url, runner: environment.runner)
    }

    func loadHistory() async throws -> [CommandHistoryEntry] {
        try await environment.history.entries(limit: 200)
    }

    func loadPreferences() async throws -> UpdatePreferences {
        preferences
    }

    func loadChangeEvents() async -> [EnvironmentChangeEvent] {
        await environment.changes.events(since: nil)
    }

    // MARK: Planning

    func planUpdate(_ installations: [InstallationRef]) async throws -> PreparedOperation {
        let prepared = try await environment.operations.prepareUpdateAll(installations.map(\.installationID))
        return PreparedOperation(plans: prepared.map(Self.plan))
    }

    func planUninstall(_ installation: InstallationRef, leftovers: [String]) async throws -> PreparedOperation {
        try await single(.uninstall(installation.installationID, leftovers: leftovers))
    }

    func planCleanLeftovers(tool: ToolID, paths: [String]) async throws -> PreparedOperation {
        try await single(.cleanLeftovers(tool, paths: paths))
    }

    func leftovers(for tool: ToolID) async -> [LeftoverItem] {
        await environment.operations.leftovers(for: tool)
    }

    func planService(_ action: ServiceAction, service: ToolService) async throws -> PreparedOperation {
        try await single(.service(action, name: service.name, provider: service.providerID))
    }

    func planCleanup(_ candidate: CleanupCandidate) async throws -> PreparedOperation {
        try await single(.cleanup(candidateID: candidate.id))
    }

    func planMoveToTrash(paths: [String], toolID: ToolID?) async throws -> PreparedOperation {
        var plans: [PreparedPlan] = []
        for path in paths {
            plans.append(Self.plan(try await environment.operations.prepare(.moveToTrash(path: path))))
        }
        return PreparedOperation(plans: plans)
    }

    func planRefreshMetadata(provider: ProviderID) async throws -> PreparedOperation {
        try await single(.refreshMetadata(provider))
    }

    private func single(_ request: OperationRequest) async throws -> PreparedOperation {
        PreparedOperation(plans: [Self.plan(try await environment.operations.prepare(request))])
    }

    private static func plan(_ prepared: CLIStateApplication.PreparedOperation) -> PreparedPlan {
        PreparedPlan(plan: prepared.plan, checks: prepared.checks)
    }

    // MARK: Running

    func run(_ prepared: PreparedPlan) -> AsyncThrowingStream<OperationEvent, Error> {
        let operations = environment.operations
        let operation = CLIStateApplication.PreparedOperation(plan: prepared.plan, checks: prepared.checks)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(4096)) { continuation in
            let task = Task {
                for await progress in await operations.execute(operation) {
                    switch progress {
                    case let .step(index, _, _):
                        let steps = operation.plan.steps
                        if steps.indices.contains(index - 1) { continuation.yield(.stepStarted(steps[index - 1])) }
                    case let .output(line):
                        continuation.yield(line.stream == .stderr ? .errorOutput(line.text) : .output(line.text))
                    case .verifying:
                        break
                    case let .finished(outcome):
                        continuation.yield(.finished(Self.outcome(outcome)))
                    }
                }
                continuation.finish()
            }
            // The mutation keeps running if the UI stops listening (§90).
            continuation.onTermination = { _ in _ = task }
        }
    }

    private nonisolated static func outcome(_ outcome: CLIStateApplication.OperationOutcome) -> OperationOutcome {
        switch outcome.status {
        case .succeeded:
            var versions: [String: String] = [:]
            for target in outcome.plan.targets {
                guard let id = target.installationID, let version = outcome.verifiedVersions[id] else { continue }
                versions[target.packageName] = version
            }
            return .succeeded(verifiedVersions: versions)
        case .unverified:
            return outcome.failure?.reason == .versionUnchanged ? .versionUnchanged : .unverified
        case .cancelled:
            return .cancelled
        case .failed, .interrupted, .running:
            return .failed(outcome.failure ?? OperationFailure(reason: .unknown))
        }
    }

    // MARK: Preferences

    func setPolicy(_ policy: AutoUpdatePolicy?, for tool: ToolID) async throws -> UpdatePreferences {
        preferences.toolPolicies[tool] = policy
        try persist()
        return preferences
    }

    func skipVersion(_ version: String?, for installation: InstallationID) async throws -> UpdatePreferences {
        preferences.skippedVersions[installation] = version
        try persist()
        return preferences
    }

    func savePreferences(_ preferences: UpdatePreferences) async throws {
        self.preferences = preferences
        try persist()
    }

    private func persist() throws {
        try preferencesStore.save(preferences)
    }
}
