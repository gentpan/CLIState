import CLIStateDomain
import Foundation

/// The only place in CLIState that starts processes (§79).
///
/// Each command runs as the leader of its own process group with stdin on
/// /dev/null, exactly `environment.applying(command.environmentOverrides)` as
/// its environment, and no shell in between. Timeouts and cancellation send
/// SIGTERM to the whole group, then SIGKILL after `killGracePeriod`, so helpers
/// the command spawned are terminated too.
public struct ProcessCommandRunner: CommandRunning {
    public var killGracePeriod: Duration
    /// After the main process exits, how long to wait for its pipes to reach EOF
    /// before giving up on a descendant that inherited them.
    public var outputDrainGracePeriod: Duration
    /// Per-pipe budget for complete read-command output. Overflow terminates the command.
    public var captureByteLimit: Int
    /// Per-pipe prefix retained in a streamed command's final result.
    public var streamCaptureByteLimit: Int
    static let streamEventLimit = 4096

    public init(killGracePeriod: Duration = .seconds(2), outputDrainGracePeriod: Duration = .milliseconds(500), captureByteLimit: Int = 16 * 1024 * 1024, streamCaptureByteLimit: Int = 1024 * 1024) {
        self.killGracePeriod = killGracePeriod
        self.outputDrainGracePeriod = outputDrainGracePeriod
        self.captureByteLimit = max(1, captureByteLimit)
        self.streamCaptureByteLimit = max(1, streamCaptureByteLimit)
    }

    /// Resolves once the process has exited and its output is collected. On
    /// cancellation it waits for the main process to exit before throwing.
    public func run(_ command: Command, environment: ExecutionEnvironment) async throws -> CommandResult {
        try Task.checkCancellation()
        let execution = try launch(command, environment: environment, eventHandler: nil)
        execution.start()
        let outcome = await withTaskCancellationHandler {
            await execution.waitForCompletion()
        } onCancel: {
            execution.cancel()
        }
        if outcome.wasCancelled { throw CancellationError() }
        if outcome.result.outputTruncated {
            throw CommandError.outputLimitExceeded(executable: command.executable, limit: max(1, captureByteLimit))
        }
        return outcome.result
    }

    /// The process starts immediately. Dropping or cancelling the consumer
    /// terminates the process group.
    public func stream(_ command: Command, environment: ExecutionEnvironment) -> AsyncThrowingStream<CommandEvent, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(Self.streamEventLimit)) { continuation in
            let execution: ProcessExecution
            do {
                execution = try launch(command, environment: environment) { event in
                    continuation.yield(event)
                    if case .finished = event { continuation.finish() }
                }
            } catch {
                continuation.finish(throwing: error)
                return
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { execution.cancel() }
            }
            execution.start()
        }
    }

    private func launch(_ command: Command, environment: ExecutionEnvironment, eventHandler: ProcessExecution.EventHandler?) throws -> ProcessExecution {
        let startedAt = ContinuousClock.now
        let spawned: SpawnedProcess
        do {
            spawned = try SpawnedProcess.launch(command, environment: environment.applying(command.environmentOverrides))
        } catch {
            AppLog.log(command, .launchFailed(error))
            throw error
        }
        AppLog.log(command, .started(pid: spawned.pid))
        return ProcessExecution(
            spawned: spawned,
            command: command,
            captureByteLimit: eventHandler == nil ? captureByteLimit : streamCaptureByteLimit,
            timing: .init(killGrace: killGracePeriod, drainGrace: outputDrainGracePeriod),
            startedAt: startedAt,
            eventHandler: eventHandler
        )
    }
}
