import CLIStateDomain
@testable import CLIStateEngine
import CLIStateTestSupport
import Foundation
import Testing

/// Tracks how many probes run at once.
private actor ConcurrencyProbe {
    private(set) var running = 0
    private(set) var peak = 0
    private(set) var commands: [Command] = []

    func begin(_ command: Command) {
        running += 1
        peak = max(peak, running)
        commands.append(command)
    }

    func end() { running -= 1 }
}

private struct SlowRunner: CommandRunning {
    let probe = ConcurrencyProbe()

    func run(_ command: Command, environment: ExecutionEnvironment) async throws -> CommandResult {
        await probe.begin(command)
        try await Task.sleep(for: .milliseconds(20))
        await probe.end()
        return CommandResult(exitCode: 0, stdout: Data("tool 1.2.3\n".utf8))
    }

    func stream(_ command: Command, environment: ExecutionEnvironment) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("VersionDetector")
struct VersionDetectorTests {
    @Test func limitsConcurrencyAndSetsTimeout() async {
        let scenario = EngineScenario(path: [])
        var requests: [VersionDetector.Request] = []
        for index in 0..<20 {
            let path = "/opt/tools/bin/tool\(index)"
            scenario.executable(path)
            requests.append(VersionDetector.Request(executablePath: path, probe: VersionProbe(["--version"])))
        }
        let runner = SlowRunner()
        let detector = VersionDetector(runner: runner, fileSystem: scenario.fs, environment: ExecutionEnvironment(variables: [:]))
        let (outcomes, cache) = await detector.detect(requests, cache: [:])

        #expect(outcomes.count == 20)
        #expect(cache.count == 20)
        #expect(await runner.probe.peak <= 6)
        #expect(await runner.probe.peak > 1)
        #expect(await runner.probe.commands.allSatisfy { $0.timeout == .seconds(3) })
    }

    @Test func parsesStderrAndReusesCacheUntilFileChanges() async {
        let scenario = EngineScenario(path: [])
        scenario.executable("/opt/jdk/bin/java", contents: "binary-v1")
        scenario.runner.stub("java", ["-version"], stderr: "openjdk version \"21.0.2\" 2024-01-16\n")
        let request = VersionDetector.Request(executablePath: "/opt/jdk/bin/java", probe: VersionProbe(["-version"], pattern: #"version "([^"]+)""#))
        let detector = VersionDetector(runner: scenario.runner, fileSystem: scenario.fs, environment: ExecutionEnvironment(variables: [:]))

        let first = await detector.detect([request], cache: [:])
        #expect(first.outcomes[request.key] == .probed(version: "21.0.2", probe: "java -version"))
        #expect(first.cache["/opt/jdk/bin/java"]?.version == "21.0.2")

        let second = await detector.detect([request], cache: first.cache)
        #expect(second.outcomes[request.key] == .cached(version: "21.0.2", probe: "java -version"))
        #expect(scenario.probedNames.filter { $0 == "java" }.count == 1)

        scenario.executable("/opt/jdk/bin/java", contents: "binary-v2-longer")
        let third = await detector.detect([request], cache: first.cache)
        #expect(third.outcomes[request.key] == .probed(version: "21.0.2", probe: "java -version"))
        #expect(scenario.probedNames.filter { $0 == "java" }.count == 2)
    }

    @Test func guardsRunOnceAndBlockUnsafeProbes() async {
        let scenario = EngineScenario(path: [])
        scenario.runner.stub("xcode-select", ["-p"], stderr: "error: unable to get active developer directory", exitCode: 2)
        scenario.runner.stub("java_home", [], stderr: "Unable to locate a Java Runtime.", exitCode: 1)
        scenario.executable("/usr/bin/git")
        scenario.executable("/usr/bin/python3")
        scenario.executable("/usr/bin/java")
        let requests = [
            VersionDetector.Request(executablePath: "/usr/bin/git", probe: VersionProbe(["--version"])),
            VersionDetector.Request(executablePath: "/usr/bin/python3", probe: VersionProbe(["--version"])),
            VersionDetector.Request(executablePath: "/opt/jdk/bin/java", resolvedPath: "/usr/bin/java", probe: VersionProbe(["-version"]), requiresJavaHome: true),
        ]
        let detector = VersionDetector(runner: scenario.runner, fileSystem: scenario.fs, environment: ExecutionEnvironment(variables: [:]))
        let (outcomes, cache) = await detector.detect(requests, cache: [:])

        #expect(outcomes[requests[0].key] == .skipped(.developerToolsMissing))
        #expect(outcomes[requests[1].key] == .skipped(.developerToolsMissing))
        #expect(outcomes[requests[2].key] == .skipped(.javaRuntimeMissing))
        #expect(cache.isEmpty)
        #expect(scenario.probedNames == ["xcode-select", "java_home"])

        #expect(VersionDetector.indicatesMissingStubTarget(outcomes[requests[0].key], executablePath: "/usr/bin/git"))
        #expect(VersionDetector.indicatesMissingStubTarget(outcomes[requests[2].key], executablePath: "/usr/bin/java"))
        #expect(!VersionDetector.indicatesMissingStubTarget(.skipped(.developerToolsMissing), executablePath: "/usr/bin/curl"))
        #expect(!VersionDetector.indicatesMissingStubTarget(.skipped(.javaRuntimeMissing), executablePath: "/opt/homebrew/opt/openjdk/bin/java"))
    }

    @Test func safetyChecksApplyEvenWithACachedVersion() async {
        let scenario = EngineScenario(path: [])
        scenario.executable("/usr/bin/git")
        let request = VersionDetector.Request(executablePath: "/usr/bin/git", probe: VersionProbe(["--version"]))
        let attributes = scenario.fs.attributes(atPath: "/usr/bin/git")
        let cache = ["/usr/bin/git": CachedVersion(version: "2.50.1", size: attributes?.size, modifiedAt: attributes?.modifiedAt, probe: "git --version")]
        let detector = VersionDetector(runner: scenario.runner, fileSystem: scenario.fs, environment: ExecutionEnvironment(variables: [:]))

        let available = await detector.detect([request], cache: cache)
        #expect(available.outcomes[request.key] == .cached(version: "2.50.1", probe: "git --version"))

        scenario.runner.stub("xcode-select", ["-p"], stderr: "error: unable to get active developer directory", exitCode: 2)
        let removed = await detector.detect([request], cache: cache)
        #expect(removed.outcomes[request.key] == .skipped(.developerToolsMissing))
        #expect(removed.cache.isEmpty)
        #expect(!scenario.probedNames.contains("git"))
    }
}
