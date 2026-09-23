import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing
@testable import CLIStateDiscovery

@Suite struct ShellEnvironmentLoaderTests {
    let context = DiscoveryFixtures.context()
    let capturedAt = Date(timeIntervalSince1970: 1_789_000_000)

    private func loader(_ runner: StubCommandRunner) -> ShellEnvironmentLoader {
        let date = capturedAt
        return ShellEnvironmentLoader(runner: runner, context: context, now: { date })
    }

    private func stubLoginShell(
        _ runner: StubCommandRunner,
        shell: ShellDescriptor = DiscoveryFixtures.zsh,
        candidates: [String] = [],
        result: CommandResult
    ) {
        let command = ShellEnvironmentLoader.loginShellCommand(shell: shell, shadowCandidates: candidates, context: context)
        runner.stub("env", command.arguments, result: result)
    }

    @Test func runsLoginShellUnderCleanEnvironment() async throws {
        let runner = StubCommandRunner()
        _ = try await loader(runner).load(shell: DiscoveryFixtures.zsh, shadowCandidates: ["node", "bad name"])

        let command = try #require(runner.invocations.first?.command)
        #expect(command.executable == "/usr/bin/env")
        let script = LoginShellScript.make(kind: .zsh, shadowCandidates: ["node"])
        #expect(command.arguments == [
            "-i",
            "HOME=/Users/tester",
            "USER=tester",
            "LOGNAME=tester",
            "SHELL=/bin/zsh",
            "TMPDIR=/var/folders/xy/T/",
            "LANG=zh_CN.UTF-8",
            "TERM=dumb",
            "/bin/zsh", "-l", "-i", "-c", script,
        ])
        #expect(command.timeout == .seconds(8))
        #expect(command.environmentOverrides.isEmpty)
        #expect(command.workingDirectory == "/Users/tester")
        #expect(!command.arguments.joined().contains("bad name"))
    }

    @Test func defaultsLangToUTF8WhenAppHasNone() {
        var context = DiscoveryFixtures.context()
        context.environment["LANG"] = nil
        let command = ShellEnvironmentLoader.loginShellCommand(shell: DiscoveryFixtures.zsh, shadowCandidates: [], context: context)
        #expect(command.arguments.contains("LANG=en_US.UTF-8"))
    }

    @Test func capturesSessionAndFiltersPersistedVariables() async throws {
        let runner = StubCommandRunner()
        let path = "/Users/tester/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:"
        stubLoginShell(runner, candidates: ["node"], result: CommandResult(exitCode: 0, stdout: DiscoveryFixtures.shellOutput(
            environment: [
                ("PATH", path),
                ("HOME", "/Users/tester"),
                ("HOMEBREW_PREFIX", "/opt/homebrew"),
                ("OPENAI_API_KEY", "sk-test-not-a-real-key"),
                ("HTTPS_PROXY", "http://user:pass@proxy:8080"),
                ("SHLVL", "1"),
            ],
            shadowLines: ["__CLISTATE_NAME__:node", "node: function", "node: command"],
            before: "rc noise\n"
        )))

        let session = try await loader(runner).load(shell: DiscoveryFixtures.zsh, shadowCandidates: ["node"])

        let environment = session.environment
        #expect(environment.source == .loginShell)
        #expect(environment.failureReason == nil)
        #expect(environment.capturedAt == capturedAt)
        #expect(environment.shell == DiscoveryFixtures.zsh)
        #expect(environment.path == ["/Users/tester/.local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", ""])
        #expect(environment.variables == ["PATH": path, "HOME": "/Users/tester", "HOMEBREW_PREFIX": "/opt/homebrew"])
        #expect(environment.variables["OPENAI_API_KEY"] == nil)
        #expect(environment.shadows == ["node": [ShellShadow(name: "node", kind: .function)]])

        #expect(session.execution.variables["OPENAI_API_KEY"] == "sk-test-not-a-real-key")
        #expect(session.execution.variables["HTTPS_PROXY"] == "http://user:pass@proxy:8080")
        #expect(session.execution.variables.count == 6)

        let encoded = String(decoding: try JSONEncoder().encode(environment), as: UTF8.self)
        #expect(!encoded.contains("sk-test"))
        #expect(!encoded.contains("proxy"))
        #expect(runner.invocations.count == 1)
    }

    @Test func timeoutFallsBackToPathHelper() async throws {
        let runner = StubCommandRunner()
        stubLoginShell(runner, result: CommandResult(exitCode: 15, stdout: Data("partial".utf8), termination: .timedOut))
        runner.stub("path_helper", ["-s"], stdout: """
        PATH="/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"; export PATH;
        MANPATH="/usr/share/man:/usr/local/share/man"; export MANPATH;

        """)

        let session = try await loader(runner).load(shell: DiscoveryFixtures.zsh, shadowCandidates: [])

        #expect(session.environment.source == .fallback)
        #expect(session.environment.failureReason?.contains("timed out") == true)
        #expect(session.environment.path == ["/usr/local/bin", "/System/Cryptexes/App/usr/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        #expect(session.environment.shadows.isEmpty)
        #expect(session.environment.variables["XPC_SERVICE_NAME"] == nil)
        #expect(session.execution.variables["XPC_SERVICE_NAME"] == "application.dev.clistate")
        #expect(session.execution.variables["PATH"] == "/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(session.execution.variables["SHELL"] == "/bin/zsh")

        let helper = try #require(runner.invocations.last?.command)
        #expect(helper.executable == "/usr/libexec/path_helper")
        #expect(helper.arguments == ["-s"])
    }

    @Test func pathHelperDoesNotInheritAppPATH() async throws {
        let runner = RecordingEnvironmentRunner()
        _ = try await ShellEnvironmentLoader(runner: runner, context: context).load(shell: DiscoveryFixtures.zsh, shadowCandidates: [])
        let environments = runner.environments
        #expect(environments.count == 2)
        #expect(environments.last?["PATH"] == nil)
        #expect(environments.last?["HOME"] == "/Users/tester")
    }

    @Test func missingMarkersFallBack() async throws {
        let runner = StubCommandRunner()
        stubLoginShell(runner, result: CommandResult(exitCode: 0, stdout: Data("PATH=/usr/bin\n".utf8)))
        runner.stub("path_helper", ["-s"], stdout: "PATH=\"/usr/bin:/bin\"; export PATH;\n")

        let session = try await loader(runner).load(shell: DiscoveryFixtures.zsh, shadowCandidates: [])

        #expect(session.environment.source == .fallback)
        #expect(session.environment.failureReason == "login shell output markers missing")
        #expect(session.environment.path == ["/usr/bin", "/bin"])
    }

    @Test func nonZeroExitWithoutMarkersFallsBack() async throws {
        let runner = StubCommandRunner()
        stubLoginShell(runner, result: CommandResult(exitCode: 1, stderr: Data("zsh: parse error".utf8)))
        runner.stub("path_helper", ["-s"], stdout: "PATH=\"/usr/bin:/bin\"; export PATH;\n")

        let session = try await loader(runner).load(shell: DiscoveryFixtures.zsh, shadowCandidates: [])

        #expect(session.environment.source == .fallback)
        #expect(session.environment.failureReason?.contains("status 1") == true)
    }

    @Test func launchFailureAndMissingPathHelperUseDefaultPATH() async throws {
        let runner = StubCommandRunner(fallback: CommandResult(exitCode: 127))
        let session = try await loader(runner).load(shell: ShellDescriptor(executable: "/bin/tcsh", kind: .other), shadowCandidates: [])

        #expect(session.environment.source == .fallback)
        #expect(session.environment.path == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        #expect(session.environment.failureReason?.contains("path_helper unavailable") == true)
    }

    @Test func cancellationIsRethrown() async {
        let runner = ThrowingRunner(error: CancellationError())
        await #expect(throws: CancellationError.self) {
            try await ShellEnvironmentLoader(runner: runner, context: context).load(shell: DiscoveryFixtures.zsh, shadowCandidates: [])
        }
    }

    @Test func startErrorFallsBack() async throws {
        let runner = ThrowingRunner(error: CommandError.executableNotFound("/usr/bin/env"))
        let session = try await ShellEnvironmentLoader(runner: runner, context: context).load(shell: DiscoveryFixtures.zsh, shadowCandidates: [])
        #expect(session.environment.source == .fallback)
        #expect(session.environment.failureReason?.contains("could not start") == true)
    }

    @Test func parsesPathHelperOutput() {
        #expect(ShellEnvironmentLoader.parsePathHelperOutput("PATH=\"/a b/bin:/usr/bin\"; export PATH;\n") == "/a b/bin:/usr/bin")
        #expect(ShellEnvironmentLoader.parsePathHelperOutput("MANPATH=\"/x\"; export MANPATH;\n") == nil)
        #expect(ShellEnvironmentLoader.parsePathHelperOutput("setenv PATH \"/usr/bin\";") == nil)
    }
}

@Suite struct ShellDetectorTests {
    @Test func prefersUserDatabaseShell() {
        let fs = InMemoryFileSystem()
        fs.addExecutable("/opt/homebrew/bin/fish")
        fs.addExecutable("/bin/zsh")
        let context = DiscoveryFixtures.context(loginShell: "/opt/homebrew/bin/fish", environment: ["SHELL": "/bin/zsh"])

        let shell = ShellDetector(context: context, fileSystem: fs).detect()

        #expect(shell == ShellDescriptor(executable: "/opt/homebrew/bin/fish", kind: .fish))
    }

    @Test func fallsBackToShellVariableThenZsh() {
        let fs = InMemoryFileSystem()
        fs.addExecutable("/bin/bash")
        let missingLoginShell = DiscoveryFixtures.context(loginShell: "/usr/local/bin/fish", environment: ["SHELL": "/bin/bash"])
        #expect(ShellDetector(context: missingLoginShell, fileSystem: fs).detect() == ShellDescriptor(executable: "/bin/bash", kind: .bash))

        let nothing = DiscoveryFixtures.context(loginShell: nil, environment: ["SHELL": "relative/zsh"])
        #expect(ShellDetector(context: nothing, fileSystem: fs).detect() == ShellDescriptor(executable: "/bin/zsh", kind: .zsh))
    }

    @Test func classifiesKinds() {
        #expect(ShellDetector.kind(forExecutable: "/bin/zsh") == .zsh)
        #expect(ShellDetector.kind(forExecutable: "/opt/homebrew/bin/bash") == .bash)
        #expect(ShellDetector.kind(forExecutable: "/usr/local/bin/fish") == .fish)
        #expect(ShellDetector.kind(forExecutable: "/bin/sh") == .sh)
        #expect(ShellDetector.kind(forExecutable: "/bin/tcsh") == .other)
    }

    @Test func rejectsShellPathsThatEnvWouldTreatAsAssignments() {
        let context = DiscoveryFixtures.context(loginShell: "/opt/a=b/zsh", environment: ["SHELL": "/bin/bash"])
        #expect(ShellDetector(context: context).detect().executable == "/bin/bash")
    }
}

/// Records the environment passed to each command; every command fails.
private final class RecordingEnvironmentRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String: String]] = []

    var environments: [[String: String]] { lock.withLock { recorded } }

    func run(_ command: Command, environment: ExecutionEnvironment) async throws -> CommandResult {
        lock.withLock { recorded.append(environment.variables) }
        return CommandResult(exitCode: 1)
    }

    func stream(_ command: Command, environment: ExecutionEnvironment) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct ThrowingRunner: CommandRunning {
    let error: any Error & Sendable

    func run(_ command: Command, environment: ExecutionEnvironment) async throws -> CommandResult {
        throw error
    }

    func stream(_ command: Command, environment: ExecutionEnvironment) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}
