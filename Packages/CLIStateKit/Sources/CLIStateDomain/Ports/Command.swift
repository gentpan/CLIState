import Foundation

/// An external process invocation. Arguments are always passed separately to
/// the process; nothing is ever interpolated into a shell string (§50).
public struct Command: Hashable, Codable, Sendable {
    public var executable: String
    public var arguments: [String]
    /// Non-secret overrides layered on top of the execution environment,
    /// e.g. `HOMEBREW_NO_AUTO_UPDATE=1`. Safe to persist.
    public var environmentOverrides: [String: String]
    public var workingDirectory: String?
    public var timeout: Duration?

    public init(
        executable: String,
        arguments: [String] = [],
        environmentOverrides: [String: String] = [:],
        workingDirectory: String? = nil,
        timeout: Duration? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environmentOverrides = environmentOverrides
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    /// Human-readable form for confirmation sheets and history, e.g.
    /// `brew upgrade php`. Uses the executable's file name and POSIX quoting.
    public var displayString: String {
        let name = (executable as NSString).lastPathComponent
        return ([name] + arguments.map(Self.shellQuoted)).joined(separator: " ")
    }

    /// Full form including the absolute executable path.
    public var fullDisplayString: String {
        ([Self.shellQuoted(executable)] + arguments.map(Self.shellQuoted)).joined(separator: " ")
    }

    static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct CommandResult: Sendable {
    public enum Termination: Equatable, Sendable {
        case exited
        case timedOut
        case signaled(Int32)
    }

    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var termination: Termination
    public var duration: Duration
    /// Stream consumers receive bounded output captures; line events continue independently.
    public var outputTruncated: Bool

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data(), termination: Termination = .exited, duration: Duration = .zero, outputTruncated: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.termination = termination
        self.duration = duration
        self.outputTruncated = outputTruncated
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { termination == .exited && exitCode == 0 }
}

public enum CommandEvent: Sendable {
    case started(pid: Int32)
    /// One line of output without its trailing newline. ANSI escapes are kept;
    /// presentation layers strip them.
    case stdout(String)
    case stderr(String)
    case finished(CommandResult)
}

public enum CommandError: Error, Equatable, Sendable {
    case executableNotFound(String)
    case launchFailed(executable: String, reason: String)
    /// Complete capture exceeded the per-pipe budget; partial output must not be parsed.
    case outputLimitExceeded(executable: String, limit: Int)
}

/// The in-memory environment used to run child processes. Holds the user's
/// full login-shell environment (proxies, tokens referenced by .npmrc, …).
/// Deliberately not Codable: it is never persisted or logged (C11).
public struct ExecutionEnvironment: Sendable {
    public var variables: [String: String]

    public init(variables: [String: String]) {
        self.variables = variables
    }

    public func applying(_ overrides: [String: String]) -> [String: String] {
        variables.merging(overrides) { _, override in override }
    }

    public var path: [String] {
        (variables["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    }
}

/// All external process execution goes through this port (§79).
/// Implementations: `ProcessCommandRunner` (Infrastructure),
/// `StubCommandRunner` / `RecordingCommandRunner` (TestSupport).
public protocol CommandRunning: Sendable {
    /// Runs to completion. Throws `CommandError` if the process cannot start or
    /// its output exceeds the capture budget, and
    /// `CancellationError` if the calling task is cancelled (the process group is
    /// terminated). A non-zero exit or timeout is returned, not thrown.
    func run(_ command: Command, environment: ExecutionEnvironment) async throws -> CommandResult

    /// Streams bounded output lines, dropping older output if the consumer falls
    /// behind. The final `.finished` event is retained, with a bounded capture.
    func stream(_ command: Command, environment: ExecutionEnvironment) -> AsyncThrowingStream<CommandEvent, Error>
}
