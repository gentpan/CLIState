import CLIStateDomain
import Darwin
import Dispatch
import Foundation

/// Drives one spawned child: drains both pipes, splits lines for streaming,
/// enforces the timeout and runs the kill sequence. All mutable state is
/// confined to `queue`, which is why the class can be `@unchecked Sendable`.
final class ProcessExecution: @unchecked Sendable {
    struct Outcome: Sendable {
        var result: CommandResult
        var wasCancelled: Bool
    }

    struct Timing: Sendable {
        /// Between SIGTERM and SIGKILL.
        var killGrace: Duration
        /// How long to wait for EOF after the main process exits, in case a
        /// grandchild inherited the pipes and keeps them open.
        var drainGrace: Duration
    }

    typealias EventHandler = @Sendable (CommandEvent) -> Void

    private enum Channel {
        case stdout, stderr

        func event(_ line: String) -> CommandEvent {
            switch self {
            case .stdout: .stdout(line)
            case .stderr: .stderr(line)
            }
        }
    }

    private enum ExitStatus {
        case exited(Int32)
        case signaled(Int32)
        /// Someone else reaped the child; the status is lost.
        case unknown
    }

    private final class OutputPipe {
        let fd: Int32
        let channel: Channel
        let source: DispatchSourceRead
        var data = Data()
        var truncated = false
        var splitter = LineSplitter()
        var isOpen = true

        init(fd: Int32, channel: Channel, queue: DispatchQueue) {
            self.fd = fd
            self.channel = channel
            self.source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        }
    }

    let pid: pid_t
    private let command: Command
    private let captureByteLimit: Int
    private let timing: Timing
    private let eventHandler: EventHandler?
    private let queue: DispatchQueue
    private let startedAt: ContinuousClock.Instant
    private let stdoutPipe: OutputPipe
    private let stderrPipe: OutputPipe
    private let processSource: DispatchSourceProcess
    private let timeoutTimer: DispatchSourceTimer?
    private let readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 65_536, alignment: 1)

    private var drainTimer: DispatchSourceTimer?
    /// Fallback when the kqueue exit event is lost: a child that exits between the
    /// initial `waitid` check and the source's registration never fires `.exit`.
    private var exitPollTimer: DispatchSourceTimer?
    private var exitStatus: ExitStatus?
    private var isReaped = false
    /// The leader exited during the kill grace period. It stays a zombie until
    /// SIGKILL has been sent so its PID (the group ID) can't be reused meanwhile.
    private var reapPending = false
    private var killStarted = false
    private var killEscalated = false
    private var timedOut = false
    private var cancelled = false
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    init(spawned: SpawnedProcess, command: Command, captureByteLimit: Int, timing: Timing, startedAt: ContinuousClock.Instant, eventHandler: EventHandler?) {
        let queue = DispatchQueue(label: "com.clistate.command", target: .global(qos: .userInitiated))
        self.pid = spawned.pid
        self.command = command
        self.captureByteLimit = max(1, captureByteLimit)
        self.timing = timing
        self.eventHandler = eventHandler
        self.queue = queue
        self.startedAt = startedAt
        self.stdoutPipe = OutputPipe(fd: spawned.stdout, channel: .stdout, queue: queue)
        self.stderrPipe = OutputPipe(fd: spawned.stderr, channel: .stderr, queue: queue)
        self.processSource = DispatchSource.makeProcessSource(identifier: spawned.pid, eventMask: .exit, queue: queue)
        self.timeoutTimer = command.timeout.map { _ in DispatchSource.makeTimerSource(queue: queue) }

        // Handlers hold `self` strongly on purpose: a running command stays alive even
        // if every caller let go. The cycles end when the sources are cancelled.
        for pipe in [stdoutPipe, stderrPipe] {
            let fd = pipe.fd
            pipe.source.setEventHandler { [self] in readAvailable(from: pipe, chunkLimit: 16) }
            pipe.source.setCancelHandler { close(fd) }
        }
        processSource.setEventHandler { [self] in handleProcessEvent() }
        if let timeoutTimer, let timeout = command.timeout {
            timeoutTimer.schedule(deadline: .now() + timeout.dispatchInterval)
            timeoutTimer.setEventHandler { [self] in handleTimeout() }
        }
    }

    deinit {
        readBuffer.deallocate()
    }

    /// Emits `.started` and begins reading. Must be called exactly once.
    func start() {
        queue.async { [self] in
            eventHandler?(.started(pid: pid))
            stdoutPipe.source.resume()
            stderrPipe.source.resume()
            processSource.resume()
            timeoutTimer?.resume()
            // Covers a child that exited before the process source was armed.
            handleProcessEvent()
        }
    }

    /// Terminates the process group; the outcome is marked cancelled.
    func cancel() {
        queue.async { [self] in
            guard outcome == nil else { return }
            if !cancelled { AppLog.log(command, .cancelled) }
            cancelled = true
            beginKillSequence()
        }
    }

    func waitForCompletion() async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let outcome {
                    continuation.resume(returning: outcome)
                } else {
                    waiters.append(continuation)
                }
            }
        }
    }

    // MARK: Output

    private func readAvailable(from pipe: OutputPipe, chunkLimit: Int) {
        guard pipe.isOpen, let base = readBuffer.baseAddress else { return }
        for _ in 0..<chunkLimit {
            let count = read(pipe.fd, base, readBuffer.count)
            if count > 0 {
                let retained = min(count, captureByteLimit - pipe.data.count)
                if retained > 0 { pipe.data.append(base.assumingMemoryBound(to: UInt8.self), count: retained) }
                if retained < count {
                    pipe.truncated = true
                    // Read commands need complete JSON/text. Streamed mutations keep
                    // running while their captures and live output remain bounded.
                    if eventHandler == nil, exitStatus == nil { beginKillSequence() }
                }
                if let eventHandler {
                    let channel = pipe.channel
                    pipe.splitter.append(UnsafeRawBufferPointer(rebasing: readBuffer[..<count])) { eventHandler(channel.event($0)) }
                }
            } else if count == 0 {
                closePipe(pipe)
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                return
            } else {
                closePipe(pipe)
                return
            }
        }
    }

    private func closePipe(_ pipe: OutputPipe) {
        guard pipe.isOpen else { return }
        pipe.isOpen = false
        pipe.source.cancel()
        if let eventHandler {
            let channel = pipe.channel
            pipe.splitter.finish { eventHandler(channel.event($0)) }
        }
        if !stdoutPipe.isOpen, !stderrPipe.isOpen, exitStatus == nil {
            // Both pipes hit EOF, which almost always means the child exited.
            handleProcessEvent()
            if exitStatus == nil { startExitPolling() }
        }
        finishIfReady()
    }

    private func startExitPolling() {
        guard exitPollTimer == nil, exitStatus == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [self] in
            handleProcessEvent()
            if exitStatus != nil {
                exitPollTimer?.cancel()
                exitPollTimer = nil
            }
        }
        timer.resume()
        exitPollTimer = timer
    }

    // MARK: Lifecycle

    private func handleProcessEvent() {
        guard exitStatus == nil else { return }
        var info = siginfo_t()
        var rc: Int32
        repeat {
            // WNOWAIT: read the status but leave the zombie, so reaping can be deferred.
            rc = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        } while rc == -1 && errno == EINTR

        if rc == -1 {
            exitStatus = .unknown
            isReaped = true
        } else if info.si_pid == pid {
            switch info.si_code {
            case CLD_EXITED: exitStatus = .exited(info.si_status)
            case CLD_KILLED, CLD_DUMPED: exitStatus = .signaled(info.si_status)
            default: return
            }
        } else {
            return
        }

        processSource.cancel()
        timeoutTimer?.cancel()
        exitPollTimer?.cancel()
        exitPollTimer = nil
        if killStarted && !killEscalated {
            reapPending = true
        } else {
            reap()
        }

        if stdoutPipe.isOpen || stderrPipe.isOpen {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timing.drainGrace.dispatchInterval)
            timer.setEventHandler { [self] in drainAndClose() }
            timer.resume()
            drainTimer = timer
        }
        finishIfReady()
    }

    /// The main process is gone but a pipe is still open, so a descendant holds it.
    /// Take what is already buffered and stop waiting for EOF.
    private func drainAndClose() {
        for pipe in [stdoutPipe, stderrPipe] {
            // Bounded so a descendant writing without pause can't keep us here.
            readAvailable(from: pipe, chunkLimit: 256)
            closePipe(pipe)
        }
    }

    private func handleTimeout() {
        guard exitStatus == nil, outcome == nil, !timedOut else { return }
        timedOut = true
        AppLog.log(command, .timedOut)
        beginKillSequence()
    }

    private func beginKillSequence() {
        guard !killStarted else { return }
        killStarted = true
        signalGroup(SIGTERM)
        // A stopped process can't act on SIGTERM until it continues.
        signalGroup(SIGCONT)
        // The exit event may already have been lost; don't rely on it after signalling.
        startExitPolling()
        queue.asyncAfter(deadline: .now() + timing.killGrace.dispatchInterval) { [self] in
            killEscalated = true
            signalGroup(SIGKILL)
            if reapPending {
                reapPending = false
                reap()
            }
        }
    }

    private func signalGroup(_ signal: Int32) {
        _ = killpg(pid, signal)
        // Also the leader directly, in case it moved itself to another group.
        if !isReaped { _ = kill(pid, signal) }
    }

    private func reap() {
        guard !isReaped else { return }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        isReaped = true
    }

    private func finishIfReady() {
        if exitStatus != nil, !stdoutPipe.isOpen, !stderrPipe.isOpen {
            finish()
        }
    }

    private func finish() {
        guard outcome == nil, let exitStatus else { return }
        processSource.cancel()
        timeoutTimer?.cancel()
        drainTimer?.cancel()
        drainTimer = nil
        exitPollTimer?.cancel()
        exitPollTimer = nil

        var termination: CommandResult.Termination
        let exitCode: Int32
        switch exitStatus {
        case let .exited(code):
            exitCode = code
            termination = .exited
        case let .signaled(signal):
            // Shell convention, so callers comparing exit codes still see a failure.
            exitCode = 128 + signal
            termination = .signaled(signal)
        case .unknown:
            exitCode = -1
            termination = .exited
        }
        if timedOut { termination = .timedOut }

        let result = CommandResult(
            exitCode: exitCode,
            stdout: stdoutPipe.data,
            stderr: stderrPipe.data,
            termination: termination,
            duration: ContinuousClock.now - startedAt,
            outputTruncated: stdoutPipe.truncated || stderrPipe.truncated
        )
        let outcome = Outcome(result: result, wasCancelled: cancelled)
        self.outcome = outcome
        AppLog.log(command, .finished(result))
        eventHandler?(.finished(result))

        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
    }
}

extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        let nanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !nanoseconds.overflow else { return seconds < 0 ? .nanoseconds(0) : .never }
        let total = nanoseconds.partialValue.addingReportingOverflow(attoseconds / 1_000_000_000)
        guard !total.overflow else { return .never }
        return .nanoseconds(Int(clamping: max(0, total.partialValue)))
    }
}
