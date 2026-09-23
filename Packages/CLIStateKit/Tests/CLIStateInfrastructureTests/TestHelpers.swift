import CLIStateDomain
@testable import CLIStateInfrastructure
import Darwin
import Foundation

enum Shell {
    static let environment = ExecutionEnvironment(variables: [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
    ])

    /// Short grace periods keep the suite fast; the sequence is the same as production.
    static let runner = ProcessCommandRunner(killGracePeriod: .milliseconds(300), outputDrainGracePeriod: .milliseconds(300))

    /// Test-only: production code never builds shell strings.
    static func command(_ script: String, arguments: [String] = [], timeout: Duration? = nil, workingDirectory: String? = nil, overrides: [String: String] = [:]) -> Command {
        Command(
            executable: "/bin/sh",
            arguments: ["-c", script, "sh"] + arguments,
            environmentOverrides: overrides,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
    }
}

enum Processes {
    /// `true` once no process with this PID exists (zombies still count as existing).
    static func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    static func pids(in text: String) -> [pid_t] {
        text.split(whereSeparator: \.isNewline).compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// Polls `condition` every 10 ms until it holds or `timeout` elapses.
func waitUntil(timeout: Duration = .seconds(3), _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return try await condition()
}

final class TemporaryDirectory {
    /// Fully resolved (`/var` → `/private/var`) so it compares equal to realpath output.
    let path: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("CLIStateInfrastructureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let resolved = realpath(base.path, nil) else { throw POSIXError(.ENOENT) }
        path = String(cString: resolved)
        free(resolved)
    }

    func url(_ name: String) -> URL { URL(fileURLWithPath: path).appendingPathComponent(name) }
    func path(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Collects values across tasks without an actor hop, for assertions after the fact.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value { lock.withLock { storage } }

    func mutate(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}

/// `CommandEvent` flattened into something `Equatable`.
enum RecordedEvent: Equatable {
    case started
    case stdout(String)
    case stderr(String)
    case finished

    init(_ event: CommandEvent) {
        switch event {
        case .started: self = .started
        case let .stdout(line): self = .stdout(line)
        case let .stderr(line): self = .stderr(line)
        case .finished: self = .finished
        }
    }
}

func collect(_ stream: AsyncThrowingStream<CommandEvent, any Error>) async throws -> (events: [CommandEvent], result: CommandResult?) {
    var events: [CommandEvent] = []
    var result: CommandResult?
    for try await event in stream {
        events.append(event)
        if case let .finished(finished) = event { result = finished }
    }
    return (events, result)
}
