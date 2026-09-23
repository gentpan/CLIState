import CLIStateDomain
import Foundation

/// Identifies one installation of one tool.
struct InstallationRef: Hashable, Sendable {
    var toolID: ToolID
    var installationID: InstallationID
}

/// A plan together with the read-only checks that ran before showing it.
struct PreparedPlan: Identifiable, Hashable, Sendable {
    var plan: OperationPlan
    var checks: [PreflightCheck]

    var id: UUID { plan.id }
    var isBlocked: Bool { checks.contains(where: \.isBlocking) }
}

/// Everything one confirmation sheet covers. "Update All" spans several
/// providers, so it holds one plan per mutation scope but asks only once.
struct PreparedOperation: Identifiable, Hashable, Sendable {
    var id = UUID()
    var plans: [PreparedPlan]

    var isBlocked: Bool { plans.contains(where: \.isBlocked) }
    var allTargets: [OperationTarget] { plans.flatMap(\.plan.targets) }
}

enum OperationOutcome: Hashable, Sendable {
    /// Exit 0 and the rescan observed new versions, keyed by package name.
    case succeeded(verifiedVersions: [String: String])
    /// Exit 0 but the rescan found the same version.
    case versionUnchanged
    case unverified
    case failed(OperationFailure)
    case cancelled
}

enum OperationEvent: Sendable {
    /// A step is about to run.
    case stepStarted(OperationStep)
    case output(String)
    case errorOutput(String)
    case finished(OperationOutcome)
}

/// The boundary between the UI and whatever performs work. The app target
/// never runs processes itself: `LiveActions` wraps the Application layer's
/// coordinators, and `PreviewActions` simulates them with sample data.
@MainActor
protocol AppActions: AnyObject {
    /// Last saved snapshot, shown before the first scan finishes (§162).
    func loadCachedSnapshot() async -> EnvironmentSnapshot?
    /// Fast scan: local data plus cached latest versions.
    func refresh() async throws -> EnvironmentSnapshot
    /// Refreshes package info (`brew update`, unless it ran in the last few minutes),
    /// then a deep scan with network-backed update checks.
    func checkForUpdates() async throws -> EnvironmentSnapshot
    /// Like `checkForUpdates`, but downloads package info even if it was just refreshed.
    func forceCheckForUpdates() async throws -> EnvironmentSnapshot
    /// Runs provider cleanup dry runs and returns the snapshot with fresh candidates.
    func refreshCleanupCandidates() async -> EnvironmentSnapshot?
    func loadHistory() async throws -> [CommandHistoryEntry]
    /// Environment change timeline, newest first.
    func loadChangeEvents() async -> [EnvironmentChangeEvent]
    /// Writes a redacted diagnostics zip (§171, §172) to `url`.
    func exportDiagnostics(to url: URL) async throws
    /// Daily background pass under the user's update policy (read-only unless
    /// tools are set to automatic). `nil` when nothing ran.
    func runBackgroundCheck(preferences: UpdatePreferences, allowAutomaticInstalls: Bool) async -> BackgroundCheckResult?
    func loadPreferences() async throws -> UpdatePreferences

    func planUpdate(_ installations: [InstallationRef]) async throws -> PreparedOperation
    /// `leftovers` are paths from `leftovers(for:)`, moved to the Trash after the uninstall.
    func planUninstall(_ installation: InstallationRef, leftovers: [String]) async throws -> PreparedOperation
    func planCleanLeftovers(tool: ToolID, paths: [String]) async throws -> PreparedOperation
    /// Read-only scan for files a tool left in the home directory.
    func leftovers(for tool: ToolID) async -> [LeftoverItem]
    func planService(_ action: ServiceAction, service: ToolService) async throws -> PreparedOperation
    func planCleanup(_ candidate: CleanupCandidate) async throws -> PreparedOperation
    func planMoveToTrash(paths: [String], toolID: ToolID?) async throws -> PreparedOperation
    func planRefreshMetadata(provider: ProviderID) async throws -> PreparedOperation

    /// Runs a confirmed plan. The stream ends after `.finished`.
    func run(_ plan: PreparedPlan) -> AsyncThrowingStream<OperationEvent, Error>

    /// `nil` removes the tool override so the provider/default policy applies.
    func setPolicy(_ policy: AutoUpdatePolicy?, for tool: ToolID) async throws -> UpdatePreferences
    /// `nil` clears a previous skip.
    func skipVersion(_ version: String?, for installation: InstallationID) async throws -> UpdatePreferences
    func savePreferences(_ preferences: UpdatePreferences) async throws
}
