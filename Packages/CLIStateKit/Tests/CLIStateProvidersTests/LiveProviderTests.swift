import CLIStateDomain
import CLIStateProviders
import Foundation
import Testing

// Runs the providers against this Mac's real brew / npm / uv / pipx / pnpm /
// cargo. Read-only commands only: `LiveCommandRunner` refuses anything that
// could mutate.
//
//     ENABLE_LIVE_PROVIDER_TESTS=1 swift test --filter LiveProviderTests

private let liveEnabled = ProcessInfo.processInfo.environment["ENABLE_LIVE_PROVIDER_TESTS"] == "1"

@Suite("Live providers", .enabled(if: liveEnabled), .serialized)
struct LiveProviderTests {
    let runner = LiveCommandRunner()
    let fileSystem = LiveFileSystem()
    let context = LiveContext.make()

    @Test(.timeLimit(.minutes(3)))
    func homebrew() async throws {
        let provider = HomebrewProvider(runner: runner, fileSystem: fileSystem)
        guard context.resolveExecutable("brew") != nil else { return }

        let availability = await provider.availability(context: context)
        #expect(availability.isAvailable)
        #expect(availability.version != nil)

        let inventory = try await provider.scan(context: context, depth: .deep)
        #expect(!inventory.tools.isEmpty)
        #expect(inventory.layout[.homebrewCellar] != nil)
        #expect(inventory.tools.contains { !$0.executableNames.isEmpty })

        if let outdated = inventory.tools.first(where: { $0.kind == .formula && $0.isOutdated == true && !$0.isPinned }) {
            let plan = try provider.updatePlan(for: [outdated], context: context)
            let checks = await provider.preflight(for: plan, context: context)
            #expect(checks.map(\.kind) == [.dryRun])
        }
        _ = try await provider.cleanupCandidates(context: context)

        let brewCommands = runner.recorded.filter { ($0.executable as NSString).lastPathComponent == "brew" }
        #expect(!brewCommands.isEmpty)
        #expect(brewCommands.allSatisfy { $0.environmentOverrides["HOMEBREW_NO_AUTO_UPDATE"] == "1" })
    }

    @Test(.timeLimit(.minutes(3)))
    func npm() async throws {
        let provider = NPMProvider(runner: runner, fileSystem: fileSystem)
        guard context.resolveExecutable("npm") != nil else { return }
        let inventory = try await provider.scan(context: context, depth: .deep)
        #expect(inventory.instance != nil)
        #expect(inventory.layout[.npmGlobalRoot] != nil)
        #expect(inventory.tools.contains { $0.packageName == "npm" } || inventory.tools.isEmpty)
        _ = try await provider.cleanupCandidates(context: context)
    }

    @Test(.timeLimit(.minutes(3)))
    func uv() async throws {
        let provider = UVProvider(runner: runner, fileSystem: fileSystem)
        guard context.resolveExecutable("uv") != nil else { return }
        let inventory = try await provider.scan(context: context, depth: .deep)
        #expect(inventory.availability.version != nil)
        #expect(inventory.layout[.uvToolDir] != nil)
        _ = try await provider.cleanupCandidates(context: context)
    }

    @Test(.timeLimit(.minutes(3)))
    func pipx() async throws {
        let provider = PipxProvider(runner: runner, fileSystem: fileSystem)
        guard context.resolveExecutable("pipx") != nil else { return }
        let inventory = try await provider.scan(context: context, depth: .deep)
        #expect(inventory.availability.version != nil)
        #expect(inventory.layout[.pipxVenvs] != nil)
        #expect(inventory.tools.allSatisfy { $0.executablePaths.allSatisfy(FileManager.default.isExecutableFile(atPath:)) })
    }

    @Test(.timeLimit(.minutes(3)))
    func pnpm() async throws {
        let provider = PNPMProvider(runner: runner, fileSystem: fileSystem)
        guard context.resolveExecutable("pnpm") != nil else { return }
        let inventory = try await provider.scan(context: context, depth: .deep)
        #expect(inventory.availability.version != nil)
        #expect(inventory.layout[.pnpmGlobalRoot] != nil)
        _ = try await provider.cleanupCandidates(context: context)
    }

    @Test(.timeLimit(.minutes(3)))
    func cargo() async throws {
        let provider = CargoProvider(runner: runner, fileSystem: fileSystem)
        guard context.resolveExecutable("cargo") != nil else { return }
        #expect(await provider.availability(context: context).isAvailable)
        let inventory = try await provider.scan(context: context, depth: .deep)
        #expect(inventory.availability.version != nil)
        let bin = try #require(inventory.layout[.cargoBin])
        for tool in inventory.tools {
            #expect(!tool.installedVersions.isEmpty)
            #expect(tool.installPrefix == bin)
            #expect(tool.executablePaths.allSatisfy(FileManager.default.isExecutableFile(atPath:)), "\(tool.executablePaths)")
            // Built only; the live runner would refuse to run it anyway.
            _ = try provider.uninstallPlan(for: tool, context: context)
        }
    }
}

// MARK: - Minimal real implementations (tests cannot import Infrastructure)

enum LiveContext {
    static func make() -> ProviderContext {
        let variables = ProcessInfo.processInfo.environment
        let path = (variables["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
        var groups: [String: BinaryGroup] = [:]
        for name in ["brew", "npm", "uv", "pipx", "pnpm", "cargo"] {
            let directories = path.split(separator: ":").map(String.init)
            if let directory = directories.first(where: { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }) {
                groups[name] = BinaryGroup(executableName: name, candidates: [
                    BinaryCandidate(name: name, path: "\(directory)/\(name)", pathPriority: 1, isSymlink: false, resolvedPath: nil),
                ])
            }
        }
        var execution = variables
        execution["PATH"] = path
        let environment = ShellEnvironment(shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh), path: [], variables: [:], source: .fallback, capturedAt: Date())
        let session = ShellSession(environment: environment, execution: ExecutionEnvironment(variables: execution))
        return ProviderContext(discovery: DiscoveryResult(session: session, pathEntries: [], binaries: BinaryInventory(groups: groups)), now: Date())
    }
}

final class LiveCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [Command] = []

    var recorded: [Command] { lock.withLock { commands } }

    /// Verbs that change state unless paired with `--dry-run`.
    private static let mutatingVerbs: Set<String> = [
        "install", "uninstall", "upgrade", "update", "cleanup", "autoremove", "prune", "clean",
        "start", "stop", "restart", "link", "unlink", "pin", "unpin", "tap", "untap", "trust",
    ]

    /// Read-only commands that happen to contain a mutating verb.
    private static let readOnlyExceptions: Set<[String]> = [["install", "--list"]]

    static func isReadOnly(_ command: Command) -> Bool {
        if command.executable == "/usr/bin/du" || readOnlyExceptions.contains(command.arguments) { return true }
        return command.arguments.contains("--dry-run") || !command.arguments.contains { mutatingVerbs.contains($0) }
    }

    func run(_ command: Command, environment: ExecutionEnvironment) async throws -> CommandResult {
        guard Self.isReadOnly(command) else {
            throw CommandError.launchFailed(executable: command.executable, reason: "live tests refuse mutating commands: \(command.displayString)")
        }
        lock.withLock { commands.append(command) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clistate-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = environment.applying(command.environmentOverrides)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
        process.standardError = try FileHandle(forWritingTo: stderrURL)

        let clock = ContinuousClock()
        let start = clock.now
        // `waitUntilExit` needs a run loop and can hang on the cooperative pool.
        let exited = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        let timeout = command.timeout ?? .seconds(120)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            process.terminate()
        }
        defer { watchdog.cancel() }

        var status: Int32 = -1
        for await code in exited { status = code }
        let timedOut = process.terminationReason == .uncaughtSignal && clock.now - start >= timeout
        return CommandResult(
            exitCode: status,
            stdout: try Data(contentsOf: stdoutURL),
            stderr: try Data(contentsOf: stderrURL),
            termination: timedOut ? .timedOut : .exited,
            duration: clock.now - start
        )
    }

    func stream(_ command: Command, environment: ExecutionEnvironment) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: CommandError.launchFailed(executable: command.executable, reason: "not supported in live tests"))
        }
    }
}

struct LiveFileSystem: FileSystem {
    var homeDirectory: String { NSHomeDirectory() }

    func attributes(atPath path: String) -> FileAttributes? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let kind: FileKind = switch attributes[.type] as? FileAttributeType {
        case .typeDirectory: .directory
        case .typeSymbolicLink: .symlink
        case .typeRegular: .file
        default: .other
        }
        return FileAttributes(kind: kind, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0, isExecutable: FileManager.default.isExecutableFile(atPath: path))
    }

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }

    func destinationOfSymbolicLink(atPath path: String) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    func resolvingSymlinks(atPath path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    func isWritable(atPath path: String) -> Bool {
        FileManager.default.isWritableFile(atPath: path)
    }

    func readData(atPath path: String, maxBytes: Int?) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        return try (maxBytes.map { try handle.read(upToCount: $0) } ?? handle.readToEnd()) ?? Data()
    }
}
