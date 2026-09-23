import CLIStateDomain
import Foundation

/// When CLI State itself ran or read executables, so those accesses aren't mistaken for uses.
///
/// On APFS, running an executable updates its access time, while reading it (Mach-O
/// headers, shebangs) only does when the access time isn't already newer than the
/// modification time. CLI State runs provider commands and the login shell before the
/// engine starts, and version probes and update checks shortly after; it reads headers
/// in between.
public struct UsageActivity: Hashable, Sendable {
    /// Scan phases in which CLI State ran commands: the current scan's discovery and providers.
    public var windows: [ClosedRange<Date>]
    /// Accesses up to this date were already judged by the previous scan (which saw them).
    public var previousScanCoverage: Date?
    /// Resolved executable path → when a version probe ran it.
    public var probes: [String: Date]

    /// How long after a scan's capture its engine may still run or read executables
    /// (probes, Mach-O headers, update-source lookups).
    public static let engineTail: TimeInterval = 120
    /// A probe's process starts right after `probedAt` and times out after a few seconds.
    public static let probeTolerance: ClosedRange<TimeInterval> = -2 ... 10
    /// The login shell may run for up to 8 s before discovery records its environment.
    static let discoveryLead: TimeInterval = 10
    /// A cached or stale environment must not stretch the window over hours of real use.
    static let maxWindow: TimeInterval = 600

    public init(windows: [ClosedRange<Date>] = [], previousScanCoverage: Date? = nil, probes: [String: Date] = [:]) {
        self.windows = windows
        self.previousScanCoverage = previousScanCoverage
        self.probes = probes
    }

    /// `evaluatedAt` is when accesses are read, after the merge's own reads.
    public init(discovery: DiscoveryResult, inventories: [ProviderInventory], previous: EnvironmentSnapshot?, now: Date, evaluatedAt: Date) {
        let end = min(max(now, evaluatedAt), now.addingTimeInterval(Self.maxWindow)).addingTimeInterval(2)
        let starts = [discovery.session.environment.capturedAt.addingTimeInterval(-Self.discoveryLead)]
            + inventories.map { $0.scannedAt.addingTimeInterval(-2) }
        let start = max(starts.min() ?? now, now.addingTimeInterval(-Self.maxWindow))
        windows = start <= end ? [start ... end] : []

        // Only a snapshot that recorded usage can vouch for accesses it saw; one saved
        // before CLI State measured usage judged nothing.
        let recordedUsage = previous?.tools.contains { $0.installations.contains { $0.lastUsedAt != nil || $0.diskUsage != nil } } == true
        previousScanCoverage = recordedUsage ? previous?.capturedAt.addingTimeInterval(Self.engineTail) : nil
        probes = (previous?.versionCache ?? [:]).compactMapValues(\.probedAt)
    }

    /// `paths`: the executable as found and as resolved; probes are keyed by either.
    func isOwnAccess(_ date: Date, paths: [String]) -> Bool {
        if windows.contains(where: { $0.contains(date) }) { return true }
        return paths.contains { path in
            probes[path].map { Self.probeTolerance.contains(date.timeIntervalSince($0)) } ?? false
        }
    }
}

/// `ToolInstallation.lastUsedAt` from the primary executable's access time.
public struct LastUsedResolver: Sendable {
    /// Package managers set access times while installing (Homebrew stamps them with the
    /// pour time) and may run a fresh binary right away (post-install steps).
    public static let installGrace: TimeInterval = 60
    /// This many different executables accessed within about `burstWindow` seconds of
    /// each other count as automated, not as uses.
    public static let burstSize = 4
    public static let burstWindow: TimeInterval = 2

    private let fileSystem: any FileSystem
    private let measurer: DiskUsageMeasurer

    public init(fileSystem: any FileSystem, measurer: DiskUsageMeasurer) {
        self.fileSystem = fileSystem
        self.measurer = measurer
    }

    /// - Parameter previous: the installation with the same ID in the previous snapshot.
    public func lastUsed(_ installation: ToolInstallation, command: String?, previous: ToolInstallation?, activity: UsageActivity) -> Date? {
        guard !installation.isSystemManaged, installation.ownership.provider != .system,
              let index = MergeEngine.primaryExecutableIndex(in: installation, command: command, fileSystem: fileSystem)
        else { return nil }
        let executable = installation.executables[index]
        guard let path = executable.resolvedPath ?? fileSystem.resolvingSymlinks(atPath: executable.path),
              !AttributionEngine.isSystemLocation(path), !Self.isOnSealedVolume(path), measurer.isAllowedPath(path),
              let attributes = fileSystem.attributes(atPath: path), attributes.kind == .file,
              let accessedAt = attributes.accessedAt
        else { return nil }

        // Never run since it was installed, copied or changed.
        let changedAt = [attributes.modifiedAt, attributes.statusChangedAt].compactMap { $0 }.max()
        if let changedAt, accessedAt <= changedAt.addingTimeInterval(Self.installGrace) { return nil }

        // A use before the file last changed belongs to the file it replaced.
        var carried = previous?.lastUsedAt
        if let date = carried, let changedAt, date <= changedAt { carried = nil }
        if let coverage = activity.previousScanCoverage, previous != nil, accessedAt <= coverage { return carried }
        if activity.isOwnAccess(accessedAt, paths: [path, executable.path]) { return carried }
        return accessedAt
    }

    /// The read-only system volume, whose access times are neither kept nor meaningful.
    static func isOnSealedVolume(_ path: String) -> Bool {
        if PathUtil.isInside(path, "/usr/local") { return false }
        return ["/System", "/usr", "/bin", "/sbin"].contains { PathUtil.isInside(path, $0) }
    }
}
