import CLIStateApplication
import CLIStateDomain
import CLIStateEngine
import CLIStateInfrastructure
import Foundation

/// `clistate-probe usage [--deep]`: disk usage and last use per installation, plus
/// what measuring costs. Read-only; nothing is persisted.
func runUsageCommand(_ arguments: [String]) async {
    let deep = arguments.contains("--deep")
    let environment = AppEnvironment.live(inMemoryPersistence: true)
    let home = environment.fileSystem.homeDirectory
    let clock = ContinuousClock()

    let started = clock.now
    guard let scanned = await environment.scan.scan(depth: deep ? .deep : .fast),
          let discovery = await environment.scan.discoveryResult
    else {
        print("scan failed")
        exit(1)
    }
    let scanTime = clock.now - started
    var inventories: [ProviderInventory] = []
    for provider in scanned.providers {
        if let inventory = await environment.scan.inventory(for: provider.providerID) { inventories.append(inventory) }
    }

    // Engine-only timings on the same inputs, reusing the version cache so no probe runs:
    // without walking directories, walking every installation, and carrying measurements forward.
    func engine(_ policy: DiskUsagePolicy) -> SnapshotEngine {
        SnapshotEngine(fileSystem: environment.fileSystem, commandRunner: environment.runner, registry: environment.registry, updateSources: [], diskUsagePolicy: policy)
    }
    var unmeasured = scanned
    for toolIndex in unmeasured.tools.indices {
        for index in unmeasured.tools[toolIndex].installations.indices { unmeasured.tools[toolIndex].installations[index].diskUsage = nil }
    }
    func timed(_ policy: DiskUsagePolicy, depth: ScanDepth, previous: EnvironmentSnapshot) async -> (EnvironmentSnapshot, Duration) {
        let start = clock.now
        let snapshot = await engine(policy).buildSnapshot(discovery: discovery, inventories: inventories, failedProviders: [:], previous: previous, depth: depth, now: Date())
        return (snapshot, clock.now - start)
    }
    let (_, baseline) = await timed(DiskUsagePolicy(fastScanLimit: 0), depth: .fast, previous: unmeasured)
    let (measured, full) = await timed(.standard, depth: .deep, previous: unmeasured)
    let (_, carried) = await timed(.standard, depth: .deep, previous: measured)

    let snapshot = deep ? measured : scanned
    let rows = snapshot.tools.flatMap { tool in tool.installations.map { (tool: tool, installation: $0) } }
    let sized = rows.filter { $0.installation.diskUsage != nil }.sorted { $0.installation.diskUsage!.bytes > $1.installation.diskUsage!.bytes }
    let used = rows.filter { $0.installation.lastUsedAt != nil }.sorted { $0.installation.lastUsedAt! > $1.installation.lastUsedAt! }
    let total = sized.reduce(Int64(0)) { $0 + $1.installation.diskUsage!.bytes }
    let partial = sized.filter { $0.installation.diskUsage!.isPartial }.count

    func ms(_ duration: Duration) -> String { duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)) }
    func name(_ row: (tool: Tool, installation: ToolInstallation)) -> String {
        row.tool.identity.displayName.padding(toLength: 26, withPad: " ", startingAt: 0)
    }
    func provider(_ installation: ToolInstallation) -> String {
        installation.ownership.provider.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)
    }

    print("\(snapshot.depth.rawValue) scan \(ms(scanTime)) · \(rows.count) installations · \(sized.count) measured (\(partial) partial) · \(used.count) with a last use")
    print("total \(total.formatted(.byteCount(style: .file))) (\(total) bytes)")
    print("engine: no directory walks \(ms(baseline)) · measuring everything \(ms(full)) (+\(ms(full - baseline))) · carrying forward \(ms(carried)) (+\(ms(carried - baseline)))")

    print("\ntop 10 by size")
    for row in sized.prefix(10) {
        let usage = row.installation.diskUsage!
        let size = usage.bytes.formatted(.byteCount(style: .file)).padding(toLength: 10, withPad: " ", startingAt: 0)
        print("  \(name(row)) \(provider(row.installation)) \(size)\(usage.isPartial ? " partial" : "")  \(PathRedaction.abbreviatingHome(row.installation.installPrefix ?? "-", home: home))")
    }

    print("\ntop 10 by last use")
    let now = Date()
    for row in used.prefix(10) {
        let date = row.installation.lastUsedAt!
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
        print("  \(name(row)) \(provider(row.installation)) \(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.colon)))  \(relative)")
    }
}
