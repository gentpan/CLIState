import CLIStateDomain
@testable import CLIStateInfrastructure
import Darwin
import Foundation
import Testing

@Suite struct ProcessCommandRunnerRunTests {
    let runner = Shell.runner

    @Test func capturesStdoutAndStderr() async throws {
        let result = try await runner.run(Shell.command("echo out; echo err >&2"), environment: Shell.environment)
        #expect(result.succeeded)
        #expect(result.termination == .exited)
        #expect(result.stdoutString == "out\n")
        #expect(result.stderrString == "err\n")
        #expect(result.duration > .zero)
    }

    @Test func nonZeroExitIsReturnedNotThrown() async throws {
        let result = try await runner.run(Shell.command("echo partial; exit 3"), environment: Shell.environment)
        #expect(result.exitCode == 3)
        #expect(result.termination == .exited)
        #expect(!result.succeeded)
        #expect(result.stdoutString == "partial\n")
    }

    @Test func reportsTerminatingSignal() async throws {
        let result = try await runner.run(Shell.command("kill -9 $$"), environment: Shell.environment)
        #expect(result.termination == .signaled(SIGKILL))
        #expect(result.exitCode == 128 + SIGKILL)
    }

    @Test func stdinIsDevNull() async throws {
        let command = Command(executable: "/bin/cat", timeout: .seconds(5))
        let result = try await runner.run(command, environment: Shell.environment)
        #expect(result.termination == .exited)
        #expect(result.stdout.isEmpty)
    }

    @Test func environmentIsBaseWithOverridesAndNothingElse() async throws {
        let environment = ExecutionEnvironment(variables: ["FOO": "base", "KEEP": "yes"])
        let command = Command(executable: "/usr/bin/env", environmentOverrides: ["FOO": "override", "EXTRA": "1"])
        let result = try await runner.run(command, environment: environment)
        let lines = Set(result.stdoutString.split(separator: "\n").map(String.init))
        #expect(lines == ["FOO=override", "KEEP=yes", "EXTRA=1"])
    }

    @Test func honoursWorkingDirectory() async throws {
        let directory = try TemporaryDirectory()
        let command = Command(executable: "/bin/pwd", arguments: ["-P"], workingDirectory: directory.path)
        let result = try await runner.run(command, environment: Shell.environment)
        #expect(result.stdoutString == directory.path + "\n")
    }

    @Test func missingWorkingDirectoryFailsToLaunch() async throws {
        let command = Command(executable: "/bin/pwd", workingDirectory: "/nonexistent-\(UUID().uuidString)")
        await #expect {
            try await runner.run(command, environment: Shell.environment)
        } throws: { error in
            if case .launchFailed = error as? CommandError { return true }
            return false
        }
    }

    @Test(arguments: ["/nonexistent/clistate-tool", "sh", "/bin"])
    func missingExecutableThrowsNotFound(executable: String) async throws {
        await #expect(throws: CommandError.executableNotFound(executable)) {
            try await runner.run(Command(executable: executable), environment: Shell.environment)
        }
    }

    @Test func nonExecutableFileThrowsNotFound() async throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("plain.txt")
        try Data("echo hi\n".utf8).write(to: URL(fileURLWithPath: path))
        await #expect(throws: CommandError.executableNotFound(path)) {
            try await runner.run(Command(executable: path), environment: Shell.environment)
        }
    }

    @Test func timeoutKillsProcessGroupIncludingGrandchild() async throws {
        let command = Shell.command("sleep 30 & echo $!; sleep 30", timeout: .milliseconds(500))
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runner.run(command, environment: Shell.environment)
        let elapsed = clock.now - start

        #expect(result.termination == .timedOut)
        #expect(elapsed < .seconds(3))
        let grandchild = try #require(Processes.pids(in: result.stdoutString).first)
        #expect(await waitUntil { Processes.isGone(grandchild) })
    }

    @Test func timeoutEscalatesToSIGKILLWhenTermIsIgnored() async throws {
        let command = Shell.command("trap '' TERM; sleep 30 & echo $!; sleep 30", timeout: .milliseconds(200))
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runner.run(command, environment: Shell.environment)
        let elapsed = clock.now - start

        #expect(result.termination == .timedOut)
        // Timeout (200 ms) plus kill grace (300 ms) before SIGKILL lands.
        #expect(elapsed >= .milliseconds(450))
        #expect(elapsed < .seconds(3))
        let grandchild = try #require(Processes.pids(in: result.stdoutString).first)
        #expect(await waitUntil { Processes.isGone(grandchild) })
    }

    @Test func cancellationKillsProcessGroupAndThrows() async throws {
        let directory = try TemporaryDirectory()
        let pidFile = directory.path("grandchild.pid")
        let command = Shell.command("sleep 30 & echo $! > \"$1\"; sleep 30", arguments: [pidFile])
        let runner = self.runner
        let task = Task { try await runner.run(command, environment: Shell.environment) }

        var grandchild: pid_t?
        _ = await waitUntil {
            grandchild = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { Processes.pids(in: $0).first }
            return grandchild != nil
        }
        let pid = try #require(grandchild)

        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - start < .seconds(2))
        #expect(await waitUntil { Processes.isGone(pid) })
    }

    @Test func alreadyCancelledTaskDoesNotLaunch() async throws {
        let directory = try TemporaryDirectory()
        let marker = directory.path("ran")
        let runner = self.runner
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(Shell.command("touch \"$1\"", arguments: [marker]), environment: Shell.environment)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test(.timeLimit(.minutes(1)))
    func largeOutputOnBothPipesDoesNotDeadlock() async throws {
        let size = 1_048_576
        let script = """
        head -c \(size) /dev/zero | tr '\\0' o &
        head -c \(size) /dev/zero | tr '\\0' e >&2
        wait
        """
        let result = try await runner.run(Shell.command(script, timeout: .seconds(20)), environment: Shell.environment)
        #expect(result.termination == .exited)
        #expect(result.stdout.count == size)
        #expect(result.stderr.count == size)
        #expect(result.stdout.allSatisfy { $0 == UInt8(ascii: "o") })
        #expect(result.stderr.allSatisfy { $0 == UInt8(ascii: "e") })
    }

    @Test func grandchildHoldingPipeDoesNotHang() async throws {
        let command = Shell.command("sleep 10 & echo $!; echo done")
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runner.run(command, environment: Shell.environment)
        let elapsed = clock.now - start

        let pids = Processes.pids(in: result.stdoutString)
        defer { pids.forEach { _ = kill($0, SIGKILL) } }
        #expect(result.succeeded)
        #expect(result.stdoutString.hasSuffix("done\n"))
        #expect(elapsed < .seconds(3))
    }
}

@Suite struct ProcessCommandRunnerStreamTests {
    let runner = Shell.runner

    @Test func emitsStartedLinesInOrderAndFinished() async throws {
        let script = "i=1; while [ $i -le 2000 ]; do echo $i; echo e$i >&2; i=$((i+1)); done"
        let (events, result) = try await collect(runner.stream(Shell.command(script), environment: Shell.environment))

        guard case let .started(pid) = events.first else {
            Issue.record("first event is not .started")
            return
        }
        #expect(pid > 0)
        #expect(events.last.map(RecordedEvent.init) == .finished)

        let stdout = events.compactMap { if case let .stdout(line) = $0 { line } else { nil } }
        let stderr = events.compactMap { if case let .stderr(line) = $0 { line } else { nil } }
        #expect(stdout == (1...2000).map(String.init))
        #expect(stderr == (1...2000).map { "e\($0)" })

        let finished = try #require(result)
        #expect(finished.succeeded)
        #expect(finished.stdoutString == stdout.map { $0 + "\n" }.joined())
    }

    @Test func flushesFinalPartialLineAndStripsCarriageReturn() async throws {
        let script = "printf 'one\\r\\ntwo\\nlast'; printf 'err-partial' >&2"
        let (events, result) = try await collect(runner.stream(Shell.command(script), environment: Shell.environment))
        let recorded = events.map(RecordedEvent.init)

        #expect(recorded.filter { if case .stdout = $0 { true } else { false } } == [.stdout("one"), .stdout("two"), .stdout("last")])
        #expect(recorded.filter { if case .stderr = $0 { true } else { false } } == [.stderr("err-partial")])
        #expect(recorded.last == .finished)
        #expect(result?.stdoutString == "one\r\ntwo\nlast")
    }

    @Test func decodesUTF8SplitAcrossWrites() async throws {
        // 中 = E4 B8 AD, 文 = E6 96 87; the first write ends mid-character.
        let script = "printf '\\344\\270'; sleep 0.2; printf '\\255\\346\\226\\207\\n'"
        let (events, _) = try await collect(runner.stream(Shell.command(script), environment: Shell.environment))
        #expect(events.map(RecordedEvent.init).contains(.stdout("中文")))
        #expect(!events.map(RecordedEvent.init).contains { if case let .stdout(line) = $0 { line.contains("\u{FFFD}") } else { false } })
    }

    @Test func missingExecutableFinishesStreamWithError() async throws {
        let stream = runner.stream(Command(executable: "/nonexistent/tool"), environment: Shell.environment)
        await #expect(throws: CommandError.executableNotFound("/nonexistent/tool")) {
            _ = try await collect(stream)
        }
    }

    @Test func timeoutFinishesWithTimedOutResult() async throws {
        let (events, result) = try await collect(runner.stream(Shell.command("echo begin; sleep 30", timeout: .milliseconds(300)), environment: Shell.environment))
        #expect(events.map(RecordedEvent.init).contains(.stdout("begin")))
        #expect(result?.termination == .timedOut)
    }

    @Test func cancellingConsumerKillsProcessGroup() async throws {
        let pids = LockedBox<[pid_t]>([])
        let stream = runner.stream(Shell.command("sleep 30 & echo $!; sleep 30"), environment: Shell.environment)
        let consumer = Task {
            for try await event in stream {
                if case let .stdout(line) = event, let pid = pid_t(line) {
                    pids.mutate { $0.append(pid) }
                }
            }
        }

        #expect(await waitUntil { !pids.value.isEmpty })
        let grandchild = try #require(pids.value.first)
        consumer.cancel()
        #expect(await waitUntil { Processes.isGone(grandchild) })
    }
}

@Suite struct LineSplitterTests {
    private func split(_ chunks: [[UInt8]]) -> [String] {
        var splitter = LineSplitter()
        var lines: [String] = []
        for chunk in chunks {
            chunk.withUnsafeBytes { splitter.append($0) { lines.append($0) } }
        }
        splitter.finish { lines.append($0) }
        return lines
    }

    @Test func keepsMultiByteCharactersSplitAtEveryByte() {
        let bytes = Array("中文\nnext\n".utf8)
        #expect(split(bytes.map { [$0] }) == ["中文", "next"])
    }

    @Test func preservesEmptyLinesAndStripsOneCarriageReturn() {
        #expect(split([Array("a\r\n\n\r\nb\r\r\n".utf8)]) == ["a", "", "", "b\r"])
    }

    @Test func flushesPartialLineOnlyAtFinish() {
        #expect(split([Array("par".utf8), Array("tial".utf8)]) == ["partial"])
        #expect(split([Array("done\n".utf8)]) == ["done"])
    }
}

@Suite("Bounded command output")
struct BoundedCommandOutputTests {
    @Test func readCaptureRejectsPartialDataAndTerminatesTheCommand() async throws {
        let runner = ProcessCommandRunner(killGracePeriod: .milliseconds(50), captureByteLimit: 1024)
        let command = Shell.command("head -c 65536 /dev/zero; sleep 30", timeout: .seconds(5))
        let start = ContinuousClock.now
        await #expect(throws: CommandError.outputLimitExceeded(executable: command.executable, limit: 1024)) {
            try await runner.run(command, environment: Shell.environment)
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func streamBoundsCapturesAndOversizedLinesWithoutStoppingMutation() async throws {
        let runner = ProcessCommandRunner(streamCaptureByteLimit: 1024)
        let command = Shell.command("head -c 65536 /dev/zero | tr '\\0' x; printf '\\nlast\\n'; head -c 65536 /dev/zero >&2", timeout: .seconds(5))
        let (events, result) = try await collect(runner.stream(command, environment: Shell.environment))
        let output = events.compactMap { if case let .stdout(line) = $0 { line } else { nil } }
        #expect(output.first == String(repeating: "x", count: LineSplitter.defaultByteLimit) + "…")
        #expect(output.last == "last")
        let finished = try #require(result)
        #expect(finished.succeeded)
        #expect(finished.outputTruncated)
        #expect(finished.stdout.count == 1024)
        #expect(finished.stderr.count == 1024)
    }

    @Test func slowStreamConsumerKeepsFinalResultAndBoundedEventCount() async throws {
        let directory = try TemporaryDirectory()
        let marker = directory.path("done")
        let command = Shell.command("i=0; while [ $i -lt 20000 ]; do echo $i; i=$((i+1)); done; touch \"$1\"", arguments: [marker])
        let stream = Shell.runner.stream(command, environment: Shell.environment)
        #expect(await waitUntil { FileManager.default.fileExists(atPath: marker) })
        let (events, result) = try await collect(stream)
        #expect(events.count <= ProcessCommandRunner.streamEventLimit + 1)
        #expect(result?.succeeded == true)
        #expect(events.map(RecordedEvent.init).contains(.stdout("19999")))
    }

    @Test func truncatedUTF8LineRecoversAtNextNewline() {
        var splitter = LineSplitter(byteLimit: 5)
        var lines: [String] = []
        for byte in "中文更多内容\n下一行\n".utf8 {
            [byte].withUnsafeBytes { splitter.append($0) { lines.append($0) } }
        }
        splitter.finish { lines.append($0) }
        #expect(lines == ["中…", "下…"])
        #expect(!lines.contains { $0.contains("\u{FFFD}") })
    }
}
