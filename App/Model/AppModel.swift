import AppKit
import CLIStateDomain
import UniformTypeIdentifiers
import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    enum ScanState: Hashable {
        case idle
        case scanning(ScanDepth)
        case failed
    }

    // MARK: State

    private(set) var snapshot: EnvironmentSnapshot?
    private(set) var scanState: ScanState = .idle
    var route: AppRoute? = .overview
    var searchText = ""
    var toolSelection: ToolID?
    var isInspectorPresented = false
    private(set) var isRefreshingMetadata = false
    private(set) var metadataRefreshError: String?
    private(set) var preferences = UpdatePreferences()
    private(set) var displaySettings: DisplaySettings
    /// Drives the confirmation sheet.
    var pendingOperation: PreparedOperation?
    /// Drives the Uninstall and Clean Up sheet, shown before the confirmation sheet.
    var leftoverReview: LeftoverReview?
    private(set) var isPreparingOperation = false
    private(set) var activity: [ActivityRun] = []
    var isActivityExpanded = false
    private(set) var history: [CommandHistoryEntry] = []
    /// Environment change timeline, shared by History and Tool Detail.
    let timeline = ChangeTimelineModel()
    var alert: AppAlert?

    let actions: any AppActions
    private var scheduler: BackgroundScheduler?
    private var operationQueue: Task<Void, Never>?
    private var lineCounter = 0
    private let defaults: UserDefaults
    /// `start()` runs once per launch, whoever asks first: the main window, the
    /// menu bar extra or a Shortcut after a background launch.
    private var launchPass: Task<Void, Never>?
    private(set) var isLaunchPassFinished = false

    init(actions: any AppActions, defaults: UserDefaults = .standard) {
        self.actions = actions
        self.defaults = defaults
        displaySettings = DisplaySettings.load(from: defaults)
        // The system setting can change behind our back (System Settings › General › Login Items).
        displaySettings.launchAtLogin = LoginItem.isEnabled
    }

    // MARK: Derived

    var homeDirectory: String {
        snapshot?.shell.variables["HOME"] ?? NSHomeDirectory()
    }

    var isScanning: Bool {
        if case .scanning = scanState { return true }
        return false
    }

    var isOperationRunning: Bool { activity.contains(where: \.isRunning) }

    var currentRun: ActivityRun? { activity.last }

    /// Tools after the Scanning settings are applied.
    var visibleTools: [Tool] {
        guard let snapshot else { return [] }
        return snapshot.tools.filter(isVisible)
    }

    func isVisible(_ tool: Tool) -> Bool {
        switch tool.identity.category {
        case .dependency where !displaySettings.showDependencies: return false
        case .unrecognized where !displaySettings.showUnrecognized: return false
        default: break
        }
        if !displaySettings.showSystemManaged, tool.installations.allSatisfy(\.isSystemManaged) { return false }
        return true
    }

    func tools(category: ToolCategory? = nil, provider: ProviderID? = nil) -> [Tool] {
        visibleTools.filter { tool in
            if let category, tool.identity.category != category { return false }
            if let provider, !tool.installations.contains(where: { $0.ownership.provider == provider }) { return false }
            return tool.matches(search: searchText)
        }
    }

    private var allUpdateItems: [UpdateItem] {
        visibleTools.flatMap { tool in
            tool.installations.filter(\.hasUpdate).map { UpdateItem(tool: tool, installation: $0) }
        }
    }

    var updateItems: [UpdateItem] {
        allUpdateItems.filter { !isSkipped($0) }
    }

    var skippedUpdateItems: [UpdateItem] {
        allUpdateItems.filter(isSkipped)
    }

    func isSkipped(_ item: UpdateItem) -> Bool {
        guard let latest = item.latestVersion else { return false }
        return preferences.skippedVersions[item.installation.id] == latest
    }

    var issues: [HealthIssue] {
        (snapshot?.issues ?? []).sorted { lhs, rhs in
            lhs.severity == rhs.severity ? lhs.id < rhs.id : lhs.severity > rhs.severity
        }
    }

    /// Providers that explain at least one visible tool, with counts.
    var providerCounts: [(provider: ProviderID, count: Int)] {
        var counts: [ProviderID: Int] = [:]
        for tool in visibleTools {
            for provider in Set(tool.installations.map(\.ownership.provider)) {
                counts[provider, default: 0] += 1
            }
        }
        return counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.displayName < rhs.key.displayName : lhs.value > rhs.value
        }
        .map { (provider: $0.key, count: $0.value) }
    }

    func providerSnapshot(_ id: ProviderID) -> ProviderSnapshot? {
        snapshot?.providers.first { $0.providerID == id }
    }

    func effectivePolicy(for tool: Tool) -> AutoUpdatePolicy {
        preferences.policy(for: tool.id, provider: tool.primaryProvider ?? .standalone)
    }

    // MARK: Navigation

    func show(tool id: ToolID) {
        toolSelection = id
        isInspectorPresented = true
        route = .tool(id)
    }

    // MARK: Scanning

    /// Starts the launch pass unless it already started. Closing and reopening
    /// the main window doesn't rescan.
    @discardableResult
    func startIfNeeded() -> Task<Void, Never> {
        if let launchPass { return launchPass }
        let task = Task {
            await start()
            isLaunchPassFinished = true
        }
        launchPass = task
        return task
    }

    func start() async {
        if snapshot == nil, let cached = await actions.loadCachedSnapshot() { snapshot = cached }
        if let loaded = try? await actions.loadPreferences() { preferences = loaded }
        if let loaded = try? await actions.loadHistory() { history = loaded }
        await refresh()
        // Latest versions for native tools and npm/uv packages need the network,
        // so the first check runs right after the local scan (read-only), unless
        // the fast scan could carry over a recent deep check.
        if preferences.defaultPolicy != .off, LatestVersionFreshness.needsDeepCheck(snapshot, now: .now, window: preferences.checkInterval.seconds) {
            await checkForUpdates()
        }
        if scheduler == nil {
            let scheduler = BackgroundScheduler(model: self, defaults: defaults)
            self.scheduler = scheduler
            scheduler.start()
        }
    }

    /// Background pass: deep scan plus opted-in automatic updates.
    func runBackgroundCheck(allowAutomaticInstalls: Bool) async -> BackgroundCheckResult? {
        guard !isScanning else { return nil }
        scanState = .scanning(.deep)
        let result = await actions.runBackgroundCheck(preferences: preferences, allowAutomaticInstalls: allowAutomaticInstalls)
        if let updated = result?.snapshot {
            snapshot = route == .cleanup ? (await actions.refreshCleanupCandidates() ?? updated) : updated
        }
        scanState = .idle
        if let loaded = try? await actions.loadHistory() { history = loaded }
        return result
    }

    func refresh() async {
        await scan(.fast) { try await self.actions.refresh() }
    }

    func checkForUpdates() async {
        await scan(.deep) { try await self.actions.forceCheckForUpdates() }
    }

    /// Re-downloads package info (`brew update`) even if it ran minutes ago, then checks.
    func forceCheckForUpdates() async {
        await scan(.deep) { try await self.actions.forceCheckForUpdates() }
    }

    private func scan(_ depth: ScanDepth, _ work: () async throws -> EnvironmentSnapshot) async {
        guard !isScanning, !isRefreshingMetadata else { return }
        scanState = .scanning(depth)
        do {
            let updated = try await work()
            // Provider cleanup previews are loaded on demand. A normal scan omits
            // them, so rebuild the preview before publishing a Cleanup-page scan.
            snapshot = route == .cleanup ? (await actions.refreshCleanupCandidates() ?? updated) : updated
            migrateToolPolicies()
            scanState = .idle
        } catch {
            scanState = .failed
            alert = AppAlert(title: String(localized: "Scan failed"), message: error.localizedDescription)
        }
    }

    /// Keeps per-tool auto-update policies when a package's tool ID changes, e.g. after
    /// it gains a registry entry (`homebrew.cocoapods` → `cocoapods`).
    private func migrateToolPolicies() {
        guard let snapshot, let migrated = preferences.migratingToolIDs(in: snapshot) else { return }
        preferences = migrated
        Task { try? await actions.savePreferences(migrated) }
    }

    /// Provider cleanup previews run dry-run commands, so they load on demand.
    func refreshCleanupCandidates() async {
        guard !isScanning, let updated = await actions.refreshCleanupCandidates() else { return }
        snapshot = updated
    }

    // MARK: Preparing operations

    func requestUpdate(_ refs: [InstallationRef]) {
        guard !refs.isEmpty else { return }
        prepare { try await self.actions.planUpdate(refs) }
    }

    func requestUpdateAll() {
        guard !isScanning, !isOperationRunning else { return }
        prepare {
            do {
                self.isRefreshingMetadata = true
                defer { self.isRefreshingMetadata = false }
                self.snapshot = try await self.actions.forceCheckForUpdates()
            }
            self.migrateToolPolicies()
            let refs = self.updateItems.filter { ToolActionsAvailable.canUpdate($0.installation) }.map(\.ref)
            guard !refs.isEmpty else {
                throw NSError(domain: "UpdateAll", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "No eligible updates remain after refreshing package information.")])
            }
            return try await self.actions.planUpdate(refs)
        }
    }

    func requestUninstall(_ ref: InstallationRef, leftovers: [String] = []) {
        prepare { try await self.actions.planUninstall(ref, leftovers: leftovers) }
    }

    func reviewLeftovers(_ review: LeftoverReview) {
        guard !isPreparingOperation else { return }
        leftoverReview = review
    }

    func requestCleanLeftovers(tool: ToolID, paths: [String]) {
        guard !paths.isEmpty else { return }
        prepare { try await self.actions.planCleanLeftovers(tool: tool, paths: paths) }
    }

    func leftovers(for tool: ToolID) async -> [LeftoverItem] {
        await actions.leftovers(for: tool)
    }

    func requestService(_ action: ServiceAction, service: ToolService) {
        prepare { try await self.actions.planService(action, service: service) }
    }

    func requestCleanup(_ candidate: CleanupCandidate) {
        prepare { try await self.actions.planCleanup(candidate) }
    }

    func cleanupCandidate(for issue: HealthIssue) -> CleanupCandidate? {
        guard issue.type == .brokenSymlink || issue.type == .brokenActiveExecutable,
              let path = issue.paths.first else { return nil }
        return snapshot?.cleanupCandidates.first {
            $0.kind == .brokenSymlink && $0.plan != nil && $0.paths == [path]
        }
    }

    /// Recheck the selected issue paths before preparing a scoped cleanup preview.
    func requestIssueCleanup(_ issues: [HealthIssue]) {
        guard !isScanning, !isOperationRunning else { return }
        let paths = Set(issues.compactMap { cleanupCandidate(for: $0)?.paths.first })
        guard !paths.isEmpty else { return }
        prepare {
            let refreshed = try await self.actions.refresh()
            self.snapshot = refreshed
            var plans: [PreparedPlan] = []
            for candidate in refreshed.cleanupCandidates where candidate.kind == .brokenSymlink && candidate.plan != nil && candidate.paths.count == 1 && paths.contains(candidate.paths[0]) {
                plans += try await self.actions.planCleanup(candidate).plans
            }
            guard !plans.isEmpty else {
                throw NSError(domain: "IssueHandling", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "These links no longer need cleanup. Review the latest results.")])
            }
            return PreparedOperation(plans: plans)
        }
    }

    func requestMoveToTrash(paths: [String], toolID: ToolID?) {
        prepare { try await self.actions.planMoveToTrash(paths: paths, toolID: toolID) }
    }

    func requestRefreshMetadata(_ provider: ProviderID) {
        guard !isRefreshingMetadata, !isScanning, !isPreparingOperation, !isOperationRunning else { return }
        isRefreshingMetadata = true
        metadataRefreshError = nil
        Task {
            defer { isRefreshingMetadata = false }
            do {
                let prepared = try await actions.planRefreshMetadata(provider: provider)
                guard !prepared.plans.isEmpty, !prepared.isBlocked,
                      prepared.plans.allSatisfy({ $0.plan.kind == .refreshMetadata }) else {
                    metadataRefreshError = String(localized: "Package information could not be refreshed. Check provider availability and try again.")
                    return
                }
                for plan in prepared.plans { await execute(plan) }
                // Refresh local results after the metadata operation; do not download twice.
                snapshot = try await actions.refresh()
                migrateToolPolicies()
                if let loaded = try? await actions.loadHistory() { history = loaded }
            } catch {
                metadataRefreshError = error.localizedDescription
            }
        }
    }

    /// Build one confirmation from freshly checked cleanup candidates and optional updates.
    func requestEnvironmentHandling(cleanBrokenLinks: Bool, installUpdates: Bool) {
        guard !isScanning, !isOperationRunning else { return }
        prepare {
            var plans: [PreparedPlan] = []
            if cleanBrokenLinks {
                guard let refreshed = await self.actions.refreshCleanupCandidates() else {
                    throw NSError(domain: "EnvironmentHandling", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not refresh cleanup candidates. Check again before handling issues.")])
                }
                self.snapshot = refreshed
                for candidate in refreshed.cleanupCandidates where candidate.kind == .brokenSymlink && candidate.plan != nil {
                    plans += try await self.actions.planCleanup(candidate).plans
                }
            }
            if installUpdates {
                let refs = self.updateItems.filter { ToolActionsAvailable.canUpdate($0.installation) }.map(\.ref)
                if !refs.isEmpty { plans += try await self.actions.planUpdate(refs).plans }
            }
            guard !plans.isEmpty else {
                throw NSError(domain: "EnvironmentHandling", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "No executable actions in the selected categories. PATH configuration and installation conflicts need individual review.")])
            }
            return PreparedOperation(plans: plans)
        }
    }

    func requestRecommendedInstall(_ items: [RecommendedTool]) {
        guard !isScanning, !isOperationRunning, !items.isEmpty else { return }
        prepare {
            guard let installer = self.actions as? any RestoreActions else {
                throw NSError(domain: "Discover", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Installation is unavailable in this session.")])
            }
            let available = items.filter { $0.installedTool(in: self.snapshot?.tools ?? []) == nil }
            guard !available.isEmpty else {
                throw NSError(domain: "Discover", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "These tools are already installed.")])
            }
            return try await installer.planInstall([RestoreProviderGroup(provider: .homebrew, items: available.map(\.profileItem))], snapshot: self.snapshot)
        }
    }

    private func prepare(_ work: @escaping @MainActor () async throws -> PreparedOperation) {
        guard !isPreparingOperation, !isRefreshingMetadata else { return }
        isPreparingOperation = true
        Task {
            defer { isPreparingOperation = false }
            do {
                pendingOperation = try await work()
            } catch {
                alert = AppAlert(title: String(localized: "Couldn't prepare the operation"), message: error.localizedDescription)
            }
        }
    }

    // MARK: Running operations

    /// Queues a confirmed operation. Operations run one after another.
    func confirm(_ operation: PreparedOperation) {
        pendingOperation = nil
        guard !operation.isBlocked else { return }
        let previous = operationQueue
        operationQueue = Task {
            await previous?.value
            for prepared in operation.plans {
                await execute(prepared)
            }
            await refresh()
            if case .idle = scanState, let snapshot {
                for prepared in operation.plans where prepared.plan.kind == .uninstall {
                    guard let index = activity.firstIndex(where: { $0.id == prepared.plan.id }),
                          case .succeeded = activity[index].state else { continue }
                    let toolIDs = Set(prepared.plan.targets.compactMap(\.toolID))
                    let remaining = toolIDs.compactMap { snapshot.tool($0) }.reduce(0) { $0 + $1.installations.count }
                    if remaining > 0 {
                        let provider = prepared.plan.providerID.displayName
                        activity[index].state = .succeeded(message: String(localized: "Removed the \(provider) installation; \(remaining) other installations remain"))
                    }
                }
            }
            if let loaded = try? await actions.loadHistory() { history = loaded }
        }
    }

    private func execute(_ prepared: PreparedPlan) async {
        let plan = prepared.plan
        activity = ActivityRun.pruningFinished(activity)
        activity.append(ActivityRun(id: plan.id, plan: plan, title: OperationText.title(for: plan), startedAt: .now))
        do {
            for try await event in actions.run(prepared) {
                switch event {
                case let .stepStarted(step):
                    append(.command, "$ " + OperationText.stepText(step), to: plan.id)
                case let .output(line):
                    append(.output, line, to: plan.id)
                case let .errorOutput(line):
                    append(.error, line, to: plan.id)
                case let .finished(outcome):
                    finish(plan.id, state: OperationText.resultState(plan: plan, outcome: outcome))
                }
            }
        } catch {
            append(.error, error.localizedDescription, to: plan.id)
            finish(plan.id, state: OperationText.resultState(plan: plan, outcome: .failed(OperationFailure(reason: .unknown))))
        }
        if let index = activity.firstIndex(where: { $0.id == plan.id }), activity[index].isRunning {
            finish(plan.id, state: OperationText.resultState(plan: plan, outcome: .cancelled))
        }
    }

    private func append(_ kind: ActivityLine.Kind, _ text: String, to id: UUID) {
        guard let index = activity.firstIndex(where: { $0.id == id }) else { return }
        lineCounter += 1
        activity[index].appendLine(ActivityLine(id: lineCounter, kind: kind, text: text))
    }

    private func finish(_ id: UUID, state: ActivityRun.State) {
        guard let index = activity.firstIndex(where: { $0.id == id }) else { return }
        activity[index].state = state
        activity[index].finishedAt = .now
        if case .failed = state { isActivityExpanded = true }
    }

    func clearFinishedActivity() {
        activity.removeAll { !$0.isRunning }
    }

    // MARK: Diagnostics

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clistate-diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await actions.exportDiagnostics(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                alert = AppAlert(title: String(localized: "Couldn't Export Diagnostics"), message: error.localizedDescription)
            }
        }
    }

    // MARK: Preferences

    func setPolicy(_ policy: AutoUpdatePolicy?, for tool: ToolID) {
        Task {
            do {
                preferences = try await actions.setPolicy(policy, for: tool)
            } catch {
                alert = AppAlert(title: String(localized: "Couldn't save the setting"), message: error.localizedDescription)
            }
        }
    }

    func skip(_ item: UpdateItem) {
        setSkippedVersion(item.latestVersion, for: item.installation.id)
    }

    func unskip(_ item: UpdateItem) {
        setSkippedVersion(nil, for: item.installation.id)
    }

    private func setSkippedVersion(_ version: String?, for id: InstallationID) {
        Task {
            do {
                preferences = try await actions.skipVersion(version, for: id)
            } catch {
                alert = AppAlert(title: String(localized: "Couldn't save the setting"), message: error.localizedDescription)
            }
        }
    }

    func updatePreferences(_ change: (inout UpdatePreferences) -> Void) {
        change(&preferences)
        let snapshot = preferences
        Task {
            do {
                try await actions.savePreferences(snapshot)
            } catch {
                alert = AppAlert(title: String(localized: "Couldn't save the setting"), message: error.localizedDescription)
            }
        }
    }

    func updateDisplaySettings(_ change: (inout DisplaySettings) -> Void) {
        let previous = displaySettings
        change(&displaySettings)
        if displaySettings.launchAtLogin != previous.launchAtLogin {
            do {
                try LoginItem.setEnabled(displaySettings.launchAtLogin)
            } catch {
                displaySettings.launchAtLogin = previous.launchAtLogin
                alert = AppAlert(title: String(localized: "Couldn't change the launch at login setting"), message: error.localizedDescription)
            }
        }
        if displaySettings.appearance != previous.appearance {
            displaySettings.appearance.apply()
        }
        if let data = try? JSONEncoder().encode(displaySettings) {
            defaults.set(data, forKey: DisplaySettings.defaultsKey)
        }
    }
}

extension AppModel: BackgroundCheckModel {
    var backgroundNotificationsEnabled: Bool { displaySettings.notificationsEnabled }
}
