import CLIStateDomain
import Foundation

/// Builds an `EnvironmentSnapshot` from discovery and provider inventories
/// (Milestones 3–4): provider state → attribution → merge → versions →
/// capabilities/config/architecture → latest versions → health → cleanup.
///
/// Read-only: the only processes it starts are version probes for registry tools
/// (with the F5 safety checks) and, in deep scans, update-source lookups. It also
/// records when tools were last used and, bounded, what their installations occupy.
public struct SnapshotEngine: SnapshotBuilding {
    public let registry: ToolRegistry
    let fileSystem: any FileSystem
    private let runner: any CommandRunning
    private let updateSources: [any UpdateSource]
    private let hostArchitecture: CPUArchitecture
    private let probeTimeout: Duration
    private let maxConcurrentProbes: Int
    private let endOfLife: (any EndOfLifeProviding)?
    let diskUsagePolicy: DiskUsagePolicy
    private let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - updateSources: defaults to `[NPMDistTagUpdateSource(runner: commandRunner)]`.
    ///   - clock: when probes run and accesses are read; `now` stays the snapshot's capture time.
    public init(
        fileSystem: any FileSystem,
        commandRunner: any CommandRunning,
        registry: ToolRegistry = .standard,
        updateSources: [any UpdateSource]? = nil,
        hostArchitecture: CPUArchitecture = .host,
        probeTimeout: Duration = .seconds(3),
        maxConcurrentProbes: Int = 6,
        endOfLife: (any EndOfLifeProviding)? = nil,
        diskUsagePolicy: DiskUsagePolicy = .standard,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileSystem = fileSystem
        self.runner = commandRunner
        self.registry = registry
        self.updateSources = updateSources ?? [NPMDistTagUpdateSource(runner: commandRunner)]
        self.hostArchitecture = hostArchitecture
        self.probeTimeout = probeTimeout
        self.maxConcurrentProbes = maxConcurrentProbes
        self.endOfLife = endOfLife
        self.diskUsagePolicy = diskUsagePolicy
        self.clock = clock
    }

    public func buildSnapshot(
        discovery: DiscoveryResult,
        inventories: [ProviderInventory],
        failedProviders: [ProviderID: String],
        previous: EnvironmentSnapshot?,
        depth: ScanDepth,
        now: Date
    ) async -> EnvironmentSnapshot {
        let providers = ProviderStateResolver().resolve(inventories: inventories, failedProviders: failedProviders, previous: previous, depth: depth)

        // Locator variables (CARGO_HOME, NVM_DIR…) are read from the in-memory
        // execution environment too; nothing here is persisted (C11).
        let variables = discovery.session.environment.variables.merging(discovery.session.execution.variables) { _, execution in execution }
        let context = AttributionContext(homeDirectory: fileSystem.homeDirectory, variables: variables, inventories: providers.inventories)
        let attribution = AttributionEngine(fileSystem: fileSystem, registry: registry, context: context)
        let merger = MergeEngine(fileSystem: fileSystem, registry: registry, attribution: attribution)

        let merged = merger.merge(discovery: discovery, inventories: providers.inventories, now: now)
        let measurer = DiskUsageMeasurer(fileSystem: fileSystem, registry: registry, context: context, entryLimit: diskUsagePolicy.entryLimit)
        let activity = UsageActivity(discovery: discovery, inventories: inventories, previous: previous, now: now, evaluatedAt: clock())
        let usedTools = applyLastUsed(merged.tools, previous: previous, activity: activity, measurer: measurer)
        let (probedTools, versionCache) = await detectVersions(usedTools, discovery: discovery, cache: previous?.versionCache ?? [:], now: now)
        var architectureCache: [String: CPUArchitecture] = [:]
        var tools = merger.finalize(probedTools, services: merged.services, pinnedInstallations: merged.pinnedInstallations, architectureCache: &architectureCache)
        tools = await applyLatestVersions(tools, discovery: discovery, previous: previous, depth: depth, now: now)
        let endOfLifeResult = await applyEndOfLife(tools, provider: endOfLife, depth: depth, now: now)
        tools = endOfLifeResult.tools
        tools = await applyDiskUsage(tools, previous: previous, depth: depth, measurer: measurer, now: now)

        let brokenLinks = merger.brokenLinks(in: discovery)
        let analyzed = HealthAnalyzer(registry: registry, hostArchitecture: hostArchitecture).analyze(
            tools: tools, discovery: discovery, brokenSymlinks: brokenLinks, services: merged.services, failedProviders: failedProviders
        )
        let (issues, analyzedTools) = Self.merging(endOfLifeResult.issues, into: analyzed.issues, tools: analyzed.tools)
        let cleanup = CleanupAdvisor(fileSystem: fileSystem).candidates(tools: analyzedTools, brokenSymlinks: brokenLinks)

        return EnvironmentSnapshot(
            capturedAt: now,
            depth: depth,
            shell: discovery.session.environment,
            pathEntries: discovery.pathEntries.sorted { $0.priority < $1.priority },
            brokenSymlinks: brokenLinks,
            providers: providers.snapshots,
            tools: analyzedTools.sorted { $0.id < $1.id },
            services: merged.services,
            issues: issues,
            versionCache: versionCache,
            cleanupCandidates: cleanup,
            latestCheckedAt: Self.latestCheckedAt(depth: depth, failedProviders: failedProviders, previous: previous, now: now)
        )
    }

    /// A deep scan in which every provider answered is a completed check; anything
    /// else keeps the previous check time, so launches retry after a failed check.
    static func latestCheckedAt(depth: ScanDepth, failedProviders: [ProviderID: String], previous: EnvironmentSnapshot?, now: Date) -> Date? {
        if depth == .deep, failedProviders.isEmpty { return now }
        return previous?.latestCheckedAt
    }

    // MARK: Versions (§6.6)

    /// Priority: provider inventory → version in path → probe → unknown. Inventory
    /// and path versions are set by the merge; this probes registry tools that
    /// still lack a version, and native layouts whose path version needs the
    /// executable's own report to be confirmed (C4). Never probes unknown binaries.
    /// Drops tools that exist only as OS stubs whose safety check failed (F5).
    func detectVersions(_ tools: [Tool], discovery: DiscoveryResult, cache: [String: CachedVersion], now: Date) async -> ([Tool], [String: CachedVersion]) {
        var requests: [VersionDetector.Request] = []
        var targets: [(tool: Int, installation: Int, key: String, path: String)] = []
        for (toolIndex, tool) in tools.enumerated() {
            guard let definition = tool.identity.registryID.flatMap({ registry.definition(ToolID($0)) }),
                  let probe = definition.versionProbe
            else { continue }
            for (installationIndex, installation) in tool.installations.enumerated() where Self.needsProbe(installation) {
                guard let executableIndex = MergeEngine.primaryExecutableIndex(in: installation, command: tool.resolution?.command, fileSystem: fileSystem) else { continue }
                let executable = installation.executables[executableIndex]
                let request = VersionDetector.Request(executablePath: executable.path, resolvedPath: executable.resolvedPath, probe: probe, requiresJavaHome: definition.requiresJavaHome)
                requests.append(request)
                targets.append((toolIndex, installationIndex, request.key, executable.path))
            }
        }
        guard !requests.isEmpty else { return (tools, [:]) }

        let detector = VersionDetector(runner: runner, fileSystem: fileSystem, environment: discovery.session.execution, timeout: probeTimeout, maxConcurrentProbes: maxConcurrentProbes, clock: clock)
        let (outcomes, newCache) = await detector.detect(requests, cache: cache)

        // A registry tool whose only installations are OS stubs for something absent
        // (`/usr/bin/java` without a JDK, `/usr/bin/git` without the CLT) isn't installed.
        var stubInstallations: [Int: Set<Int>] = [:]
        for target in targets where tools[target.tool].installations[target.installation].isSystemManaged
            && VersionDetector.indicatesMissingStubTarget(outcomes[target.key], executablePath: target.path) {
            stubInstallations[target.tool, default: []].insert(target.installation)
        }
        let absentTools = Set(stubInstallations.filter { tools[$0.key].installations.count == $0.value.count }.keys)

        var result = tools
        for target in targets where !absentTools.contains(target.tool) {
            let observed: (version: String, source: ObservationSource)
            switch outcomes[target.key] {
            case let .probed(version?, probe)?: observed = (version, .executable(probe))
            case let .cached(version?, _)?: observed = (version, .cache)
            default: continue
            }
            var installation = result[target.tool].installations[target.installation]
            if let pathVersion = installation.version, pathVersion.source == .path {
                installation.ownership = AttributionEngine.confirmingNative(installation.ownership, pathVersion: pathVersion.value.rawValue, probedVersion: observed.version)
                if installation.ownership.confidence == .confirmed {
                    installation.version = ObservedValue(pathVersion.value, source: .path, confidence: .confirmed, observedAt: now)
                }
            } else {
                installation.version = ObservedValue(ToolVersion(observed.version), source: observed.source, confidence: .confirmed, observedAt: now)
            }
            result[target.tool].installations[target.installation] = installation
        }
        let present = result.indices.filter { !absentTools.contains($0) }.map { result[$0] }
        return (present, newCache)
    }

    static func needsProbe(_ installation: ToolInstallation) -> Bool {
        guard installation.linkState != .broken else { return false }
        guard let version = installation.version else { return true }
        return installation.ownership.provider == .native && version.source == .path && installation.ownership.confidence != .confirmed
    }

    // MARK: Latest versions

    func applyLatestVersions(_ tools: [Tool], discovery: DiscoveryResult, previous: EnvironmentSnapshot?, depth: ScanDepth, now: Date) async -> [Tool] {
        var result = tools
        if depth == .deep {
            for index in result.indices {
                guard let definition = result[index].identity.registryID.flatMap({ registry.definition(ToolID($0)) }),
                      let sourceDefinition = definition.updateSource,
                      result[index].installations.contains(where: { $0.ownership.provider == .native }),
                      let source = updateSources.first(where: { $0.canHandle(sourceDefinition) }),
                      let latest = await source.latest(for: sourceDefinition, discovery: discovery)
                else { continue }
                for installationIndex in result[index].installations.indices where result[index].installations[installationIndex].ownership.provider == .native {
                    result[index].installations[installationIndex].latest = ObservedValue(ToolVersion(latest.latestVersion), source: .updateSource(latest.sourceID), confidence: .confirmed, observedAt: now)
                    result[index].installations[installationIndex].latestChannel = latest.channel
                }
            }
        }

        if depth == .fast, let previous {
            var prior: [InstallationID: ToolInstallation] = [:]
            for tool in previous.tools {
                for installation in tool.installations { prior[installation.id] = installation }
            }
            for toolIndex in result.indices {
                for index in result[toolIndex].installations.indices {
                    let installation = result[toolIndex].installations[index]
                    guard installation.latest == nil,
                          let old = prior[installation.id], let oldLatest = old.latest,
                          let version = installation.version?.value, old.version?.value == version
                    else { continue }
                    result[toolIndex].installations[index].latest = oldLatest
                    result[toolIndex].installations[index].latestChannel = old.latestChannel
                }
            }
        }
        return result
    }
}
