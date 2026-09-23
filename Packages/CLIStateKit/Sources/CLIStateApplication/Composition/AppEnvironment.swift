import CLIStateDiscovery
import CLIStateDomain
import CLIStateEngine
import CLIStateInfrastructure
import CLIStateProviders
import Foundation

/// Composition root (§86): the only place that knows every concrete implementation.
public struct AppEnvironment: Sendable {
    public let fileSystem: any FileSystem
    public let runner: any CommandRunning
    public let registry: ToolRegistry
    public let scan: ScanCoordinator
    public let operations: OperationCoordinator
    public let history: any CommandHistoryRepository
    public let autoUpdate: AutoUpdateRunner
    /// Environment change timeline (Lane P).
    public let changes: any EnvironmentChangeRepository
    /// endoflife.date release cycles, cached in Application Support.
    public let endOfLife: EndOfLifeCatalog

    /// Real implementations. Never throws: if the on-disk snapshot or history store
    /// can't be opened, the app still scans and runs operations, just without
    /// persisting them (the old fallback used `try!` and could crash at launch).
    /// `inMemoryPersistence` keeps everything out of Application Support (probe, tests).
    public static func live(inMemoryPersistence: Bool = false) -> AppEnvironment {
        let fileSystem = LocalFileSystem()
        let runner = ProcessCommandRunner()
        let registry = ToolRegistry.standard

        var snapshots: any SnapshotRepository = MemorySnapshotRepository()
        var history: any CommandHistoryRepository = MemoryHistoryRepository()
        var changesURL: URL?
        var endOfLifeDirectory: URL?
        if !inMemoryPersistence {
            changesURL = try? JSONChangeEventStore.defaultFileURL()
            endOfLifeDirectory = try? EndOfLifeCatalog.defaultDirectory()
            if let url = try? JSONSnapshotRepository.defaultFileURL() {
                snapshots = JSONSnapshotRepository(fileURL: url)
            }
            if let store = try? SwiftDataHistoryRepository.make() {
                history = store
            }
        }
        let changes = JSONChangeEventStore(fileURL: changesURL)
        let endOfLife = EndOfLifeCatalog(source: EndOfLifeSource(http: URLSessionHTTPClient()), directory: endOfLifeDirectory)

        let scan = ScanCoordinator(
            discovery: EnvironmentDiscovery(runner: runner, fileSystem: fileSystem, shadowCandidates: registry.commandNames),
            providers: [
                HomebrewProvider(runner: runner, fileSystem: fileSystem),
                NPMProvider(runner: runner, fileSystem: fileSystem),
                UVProvider(runner: runner, fileSystem: fileSystem),
                PipxProvider(runner: runner, fileSystem: fileSystem),
                PNPMProvider(runner: runner, fileSystem: fileSystem),
                CargoProvider(runner: runner, fileSystem: fileSystem),
            ],
            builder: SnapshotEngine(fileSystem: fileSystem, commandRunner: runner, registry: registry, endOfLife: endOfLife),
            repository: snapshots,
            recorder: EnvironmentChangeRecorder(store: changes, history: history)
        )
        let operations = OperationCoordinator(
            scan: scan,
            runner: runner,
            locks: CommandScheduler(),
            trash: LocalTrash(),
            history: history,
            fileSystem: fileSystem,
            nativePlanner: RegistryNativeUpdatePlanner(registry: registry),
            leftoverScanner: LeftoverScanner(fileSystem: fileSystem, registry: registry)
        )
        return AppEnvironment(
            fileSystem: fileSystem,
            runner: runner,
            registry: registry,
            scan: scan,
            operations: operations,
            history: history,
            autoUpdate: AutoUpdateRunner(scan: scan, operations: operations, history: history),
            changes: changes,
            endOfLife: endOfLife
        )
    }
}

/// Native installers update themselves through the command the registry
/// declares for them, e.g. `claude update`.
public struct RegistryNativeUpdatePlanner: NativeUpdatePlanning {
    let registry: ToolRegistry

    public init(registry: ToolRegistry) {
        self.registry = registry
    }

    public func selfUpdatePlan(tool: Tool, installation: ToolInstallation) -> OperationPlan? {
        guard installation.ownership.provider == .native,
              installation.ownership.permitsMutation,
              let definition = registry.definition(tool.id),
              let executable = installation.executables.first?.path,
              let command = definition.selfUpdateCommand(executablePath: executable)
        else { return nil }
        return OperationPlan(
            kind: .selfUpdate,
            providerID: .native,
            targets: [],
            commands: [command],
            requiresNetwork: true,
            mutationScope: "native:\(tool.id.rawValue)"
        )
    }
}

actor MemoryHistoryRepository: CommandHistoryRepository {
    private var rows: [UUID: CommandHistoryEntry] = [:]
    func entries(limit: Int) async throws -> [CommandHistoryEntry] {
        Array(rows.values.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }
    func upsert(_ entry: CommandHistoryEntry) async throws { rows[entry.id] = entry }
}

actor MemorySnapshotRepository: SnapshotRepository {
    private var stored: EnvironmentSnapshot?
    func load() async throws -> EnvironmentSnapshot? { stored }
    func save(_ snapshot: EnvironmentSnapshot) async throws { stored = snapshot }
}
