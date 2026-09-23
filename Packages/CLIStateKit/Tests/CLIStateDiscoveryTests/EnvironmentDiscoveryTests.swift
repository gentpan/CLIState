import CLIStateDomain
import CLIStateTestSupport
import Darwin
import Foundation
import Testing
@testable import CLIStateDiscovery

@Suite struct EnvironmentDiscoveryTests {
    @Test func composesShellPATHAndBinaries() async throws {
        let fs = DiscoveryFixtures.developerMac()
        let context = DiscoveryFixtures.context()
        let candidates = ["node", "php", "$(reboot)"]
        let runner = StubCommandRunner()
        let command = ShellEnvironmentLoader.loginShellCommand(shell: DiscoveryFixtures.zsh, shadowCandidates: candidates, context: context)
        runner.stub("env", command.arguments, result: CommandResult(exitCode: 0, stdout: DiscoveryFixtures.shellOutput(
            environment: [
                ("PATH", DiscoveryFixtures.developerPATH.joined(separator: ":")),
                ("HOMEBREW_PREFIX", "/opt/homebrew"),
                ("GITHUB_TOKEN", "ghp_fake"),
            ],
            shadowLines: ["__CLISTATE_NAME__:node", "node: alias", "node: command", "__CLISTATE_NAME__:php", "php: command"],
            before: "Last login: yesterday\n"
        )))

        let discovery = EnvironmentDiscovery(
            runner: runner,
            fileSystem: fs,
            shadowCandidates: candidates,
            hostContext: { context },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let result = try await discovery.discover()

        #expect(runner.invocations.count == 1)
        let script = try #require(runner.invocations.first?.command.arguments.last)
        #expect(script.contains("__CLISTATE_NAME__:php"))
        #expect(!script.contains("reboot"))
        #expect(result.session.environment.source == .loginShell)
        #expect(result.session.environment.shadows["node"]?.map(\.kind) == [.alias])
        #expect(result.session.environment.variables["GITHUB_TOKEN"] == nil)
        #expect(result.session.execution.variables["GITHUB_TOKEN"] == "ghp_fake")
        #expect(result.pathEntries.count == 23)
        #expect(result.pathEntries[10].executableCount == 719)
        #expect(result.pathEntries[10].isWritable)
        #expect(result.binaries.candidates(named: "node").first?.pathPriority == 10)
        #expect(result.binaries.brokenSymlinks.count == 1)
    }

    @Test func fallbackStillProducesInventory() async throws {
        let fs = DiscoveryFixtures.developerMac()
        let runner = StubCommandRunner(fallback: CommandResult(exitCode: 0, termination: .timedOut))
        runner.stub("path_helper", ["-s"], stdout: "PATH=\"/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\"; export PATH;\n")

        let result = try await EnvironmentDiscovery(
            runner: runner,
            fileSystem: fs,
            shadowCandidates: [],
            hostContext: { DiscoveryFixtures.context() }
        ).discover()

        #expect(result.session.environment.source == .fallback)
        #expect(result.pathEntries.map(\.normalizedPath) == ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        #expect(result.binaries.candidates(named: "git").first?.path == "/usr/bin/git")
    }
}

// MARK: - Live

@Suite(.enabled(if: ProcessInfo.processInfo.environment["ENABLE_LIVE_PROVIDER_TESTS"] == "1"))
struct LiveEnvironmentDiscoveryTests {
    @Test func discoversThisMac() async throws {
        let discovery = EnvironmentDiscovery(
            runner: LiveProcessRunner(),
            fileSystem: LiveFileSystem(),
            shadowCandidates: ["node", "git", "python3", "ls", "cd"]
        )

        let result = try await discovery.discover()

        #expect(result.session.environment.source == .loginShell, "\(result.session.environment.failureReason ?? "")")
        #expect(!result.session.environment.path.isEmpty)
        #expect(result.pathEntries.contains { $0.normalizedPath == "/usr/bin" && $0.status == .ok && $0.source == .system })
        #expect(!result.binaries.candidates(named: "ls").isEmpty)
        #expect(result.session.environment.shadows["cd"]?.contains { $0.kind == .builtin } == true)
    }
}

/// Minimal Process-based runner for the live test only; production code uses
/// Infrastructure's `ProcessCommandRunner`.
private struct LiveProcessRunner: CommandRunning {
    func run(_ command: Command, environment: ExecutionEnvironment) async throws -> CommandResult {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("clistate-live-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = environment.applying(command.environmentOverrides)
        if let directory = command.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice

        let clock = ContinuousClock()
        let start = clock.now
        try process.run()
        var timedOut = false
        while process.isRunning {
            if let timeout = command.timeout, clock.now - start > timeout {
                process.terminate()
                timedOut = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        process.waitUntilExit()
        try handle.close()
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: try Data(contentsOf: output),
            termination: timedOut ? .timedOut : .exited,
            duration: clock.now - start
        )
    }

    func stream(_ command: Command, environment: ExecutionEnvironment) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct LiveFileSystem: FileSystem {
    var homeDirectory: String { NSHomeDirectory() }

    func attributes(atPath path: String) -> FileAttributes? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind: FileKind = switch info.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symlink
        default: .other
        }
        return FileAttributes(
            kind: kind,
            size: Int64(info.st_size),
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
            isExecutable: info.st_mode & 0o111 != 0
        )
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
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    func isWritable(atPath path: String) -> Bool {
        access(path, W_OK) == 0
    }

    func readData(atPath path: String, maxBytes: Int?) throws -> Data {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return maxBytes.map { Data(data.prefix($0)) } ?? data
    }
}
