import CLIStateDomain
import Foundation

/// How a scan measures disk usage.
public struct DiskUsagePolicy: Hashable, Sendable {
    /// Deep scans re-measure measurements older than this, for trees that change without a
    /// new version (auto-updating app bundles, packages reinstalled in place).
    public var refreshInterval: TimeInterval
    /// A fast scan walks a directory only when at most this many installations lack a
    /// usable measurement, e.g. after an upgrade. A first scan leaves them to the deep scan.
    public var fastScanLimit: Int
    public var maxConcurrentMeasurements: Int
    public var entryLimit: Int

    public init(refreshInterval: TimeInterval = 24 * 3600, fastScanLimit: Int = 8, maxConcurrentMeasurements: Int = 4, entryLimit: Int = DiskUsageMeasurer.defaultEntryLimit) {
        self.refreshInterval = refreshInterval
        self.fastScanLimit = fastScanLimit
        self.maxConcurrentMeasurements = max(1, maxConcurrentMeasurements)
        self.entryLimit = entryLimit
    }

    public static let standard = DiskUsagePolicy()
}

extension SnapshotEngine {
    // MARK: Last used

    /// Runs before this scan probes or reads anything, so its own accesses show up only
    /// in the next scan, which knows them from the probe times and this scan's capture.
    func applyLastUsed(_ tools: [Tool], previous: EnvironmentSnapshot?, activity: UsageActivity, measurer: DiskUsageMeasurer) -> [Tool] {
        let prior = Self.installationsByID(previous)
        let resolver = LastUsedResolver(fileSystem: fileSystem, measurer: measurer)
        var result = tools.map { tool in
            var tool = tool
            for index in tool.installations.indices {
                let installation = tool.installations[index]
                tool.installations[index].lastUsedAt = resolver.lastUsed(installation, command: tool.resolution?.command, previous: prior[installation.id], activity: activity)
            }
            return tool
        }

        // Several different tools "used" within the same moment is a program running them
        // (an earlier CLI State's version probes, a build script), not a person.
        let window = LastUsedResolver.burstWindow
        var buckets: [Int: Int] = [:]
        for installation in result.flatMap(\.installations) {
            guard let date = installation.lastUsedAt else { continue }
            buckets[Int((date.timeIntervalSince1970 / window).rounded(.down)), default: 0] += 1
        }
        func isBurst(_ date: Date) -> Bool {
            let bucket = Int((date.timeIntervalSince1970 / window).rounded(.down))
            return (buckets[bucket - 1, default: 0] + buckets[bucket, default: 0] + buckets[bucket + 1, default: 0]) >= LastUsedResolver.burstSize
        }
        for toolIndex in result.indices {
            for index in result[toolIndex].installations.indices {
                guard let date = result[toolIndex].installations[index].lastUsedAt, isBurst(date) else { continue }
                let carried = prior[result[toolIndex].installations[index].id]?.lastUsedAt
                result[toolIndex].installations[index].lastUsedAt = carried.flatMap { $0 < date ? $0 : nil }
            }
        }
        return result
    }

    // MARK: Disk usage

    struct MeasurementJob: Sendable {
        var tool: Int
        var installation: Int
        var targets: [DiskUsageMeasurer.Target]
    }

    /// Carries a measurement forward while the installation ID and version are unchanged;
    /// otherwise, or when a deep scan finds it stale, walks the disk (bounded, concurrent).
    func applyDiskUsage(_ tools: [Tool], previous: EnvironmentSnapshot?, depth: ScanDepth, measurer: DiskUsageMeasurer, now: Date) async -> [Tool] {
        let prior = Self.installationsByID(previous)
        var result = tools
        var fileJobs: [MeasurementJob] = []
        var treeJobs: [MeasurementJob] = []

        for toolIndex in result.indices {
            let tool = result[toolIndex]
            for index in tool.installations.indices {
                let installation = tool.installations[index]
                result[toolIndex].installations[index].diskUsage = nil
                let targets = measurer.targets(for: installation, registryID: tool.identity.registryID)
                guard !targets.isEmpty else { continue }
                let job = MeasurementJob(tool: toolIndex, installation: index, targets: targets)

                // A few stat calls: always current, so a replaced standalone binary shows its new size.
                if targets.allSatisfy({ if case .file = $0 { true } else { false } }) {
                    fileJobs.append(job)
                    continue
                }
                let version = installation.version?.value.rawValue
                if let carried = prior[installation.id]?.diskUsage, carried.version == version {
                    let age = now.timeIntervalSince(carried.measuredAt)
                    let isStale = depth == .deep && (age >= diskUsagePolicy.refreshInterval || age < 0)
                    if !isStale {
                        result[toolIndex].installations[index].diskUsage = carried
                        continue
                    }
                }
                treeJobs.append(job)
            }
        }
        if depth == .fast, treeJobs.count > diskUsagePolicy.fastScanLimit { treeJobs = [] }

        let measurements = await measure(fileJobs + treeJobs, measurer: measurer)
        for (job, measurement) in measurements {
            let version = result[job.tool].installations[job.installation].version?.value.rawValue
            result[job.tool].installations[job.installation].diskUsage = DiskUsage(bytes: measurement.bytes, measuredAt: now, version: version, isPartial: measurement.isPartial)
        }
        return result
    }

    private func measure(_ jobs: [MeasurementJob], measurer: DiskUsageMeasurer) async -> [(MeasurementJob, DiskUsageMeasurer.Measurement)] {
        guard !jobs.isEmpty else { return [] }
        return await withTaskGroup(of: (MeasurementJob, DiskUsageMeasurer.Measurement?).self) { group in
            var collected: [(MeasurementJob, DiskUsageMeasurer.Measurement)] = []
            var iterator = jobs.makeIterator()
            var running = 0
            while running < diskUsagePolicy.maxConcurrentMeasurements, let job = iterator.next() {
                group.addTask { (job, measurer.measure(job.targets)) }
                running += 1
            }
            while let (job, measurement) = await group.next() {
                if let measurement { collected.append((job, measurement)) }
                if let next = iterator.next() {
                    group.addTask { (next, measurer.measure(next.targets)) }
                }
            }
            return collected
        }
    }

    static func installationsByID(_ snapshot: EnvironmentSnapshot?) -> [InstallationID: ToolInstallation] {
        var byID: [InstallationID: ToolInstallation] = [:]
        for tool in snapshot?.tools ?? [] {
            for installation in tool.installations where byID[installation.id] == nil {
                byID[installation.id] = installation
            }
        }
        return byID
    }
}
