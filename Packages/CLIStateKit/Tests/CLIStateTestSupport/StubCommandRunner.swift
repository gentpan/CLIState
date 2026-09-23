import CLIStateDomain
import Foundation

/// Returns canned results keyed by executable name + arguments, and records
/// every invocation so tests can assert argument arrays (§177).
///
///     let runner = StubCommandRunner()
///     runner.stub("brew", ["--version"], stdout: "Homebrew 6.0.22\n")
///     runner.stub("brew", ["info", "--json=v2", "--installed"], fixture: url)
public final class StubCommandRunner: CommandRunning, @unchecked Sendable {
    public struct Invocation: Hashable, Sendable {
        public var command: Command
        public var environmentOverrides: [String: String] { command.environmentOverrides }
    }

    private let lock = NSLock()
    private var stubs: [String: CommandResult] = [:]
    private var recorded: [Invocation] = []
    /// Result for unmatched commands. Defaults to exit 127 so missing stubs fail loudly.
    public var fallback: CommandResult

    public init(fallback: CommandResult = CommandResult(exitCode: 127, stderr: Data("no stub".utf8))) {
        self.fallback = fallback
    }

    public var invocations: [Invocation] { lock.withLock { recorded } }

    /// Match on the executable's file name (so `/opt/homebrew/bin/brew` matches `brew`).
    public func stub(_ executableName: String, _ arguments: [String], result: CommandResult) {
        lock.withLock { stubs[Self.key(executableName, arguments)] = result }
    }

    public func stub(_ executableName: String, _ arguments: [String], stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        stub(executableName, arguments, result: CommandResult(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8)))
    }

    public func stub(_ executableName: String, _ arguments: [String], fixture: URL, exitCode: Int32 = 0) throws {
        stub(executableName, arguments, result: CommandResult(exitCode: exitCode, stdout: try Data(contentsOf: fixture)))
    }

    public func run(_ command: Command, environment: ExecutionEnvironment) async throws -> CommandResult {
        try Task.checkCancellation()
        let name = (command.executable as NSString).lastPathComponent
        return lock.withLock {
            recorded.append(Invocation(command: command))
            return stubs[Self.key(name, command.arguments)] ?? fallback
        }
    }

    public func stream(_ command: Command, environment: ExecutionEnvironment) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await run(command, environment: environment)
                    continuation.yield(.started(pid: 0))
                    for line in result.stdoutString.split(separator: "\n", omittingEmptySubsequences: false).dropLast(result.stdoutString.hasSuffix("\n") ? 1 : 0) {
                        continuation.yield(.stdout(String(line)))
                    }
                    for line in result.stderrString.split(separator: "\n") {
                        continuation.yield(.stderr(String(line)))
                    }
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func key(_ name: String, _ arguments: [String]) -> String {
        ([name] + arguments).joined(separator: "\u{1F}")
    }
}

public enum Fixtures {
    /// Locates a fixture copied into a test bundle: `Fixtures/Homebrew/info-installed.json`.
    public static func url(_ relativePath: String, in bundle: Bundle) -> URL {
        guard let base = bundle.resourceURL else { fatalError("Test bundle has no resources") }
        let url = base.appendingPathComponent("Fixtures").appendingPathComponent(relativePath)
        precondition(FileManager.default.fileExists(atPath: url.path), "Missing fixture \(relativePath)")
        return url
    }

    public static func data(_ relativePath: String, in bundle: Bundle) throws -> Data {
        try Data(contentsOf: url(relativePath, in: bundle))
    }

    public static func string(_ relativePath: String, in bundle: Bundle) throws -> String {
        String(decoding: try data(relativePath, in: bundle), as: UTF8.self)
    }
}
