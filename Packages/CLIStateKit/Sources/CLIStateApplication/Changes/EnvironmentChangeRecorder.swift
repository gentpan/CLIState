import CLIStateDomain
import CLIStateEngine
import Foundation

/// Told about every snapshot a scan produces, with the one it replaces.
public protocol ScanRecording: Sendable {
    func scanFinished(previous: EnvironmentSnapshot?, current: EnvironmentSnapshot) async
}

/// Diffs each new snapshot against the previous one, attributes changes to
/// operations CLIState ran, and appends the result to the timeline.
public actor EnvironmentChangeRecorder: ScanRecording {
    private let store: any EnvironmentChangeRepository
    private let history: any CommandHistoryRepository
    private let differ: SnapshotDiffer
    private let attributor: ChangeAttributor

    public init(store: any EnvironmentChangeRepository, history: any CommandHistoryRepository, differ: SnapshotDiffer = SnapshotDiffer(), attributor: ChangeAttributor = ChangeAttributor()) {
        self.store = store
        self.history = history
        self.differ = differ
        self.attributor = attributor
    }

    public func scanFinished(previous: EnvironmentSnapshot?, current: EnvironmentSnapshot) async {
        // The first scan ever has nothing trustworthy to compare with: record one
        // baseline instead of every installed tool as "added".
        guard await store.hasEvents() else {
            await store.append(EnvironmentChangeEvent(detectedAt: current.capturedAt, depth: current.depth, isBaseline: true, toolCount: current.tools.count, changes: []))
            return
        }
        guard let previous, previous.id != current.id, previous.capturedAt <= current.capturedAt else { return }
        let changes = differ.changes(from: previous, to: current)
        guard !changes.isEmpty else { return }
        let entries = (try? await history.entries(limit: 200)) ?? []
        let attributed = attributor.attribute(changes, history: entries, since: previous.capturedAt, until: current.capturedAt)
        await store.append(EnvironmentChangeEvent(
            detectedAt: current.capturedAt,
            previousCapturedAt: previous.capturedAt,
            depth: current.depth,
            toolCount: current.tools.count,
            changes: attributed
        ))
    }
}
