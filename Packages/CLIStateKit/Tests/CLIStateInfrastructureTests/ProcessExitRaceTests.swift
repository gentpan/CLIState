import CLIStateDomain
@testable import CLIStateInfrastructure
import Foundation
import Testing

/// Regression for a lost kqueue exit event: very short-lived children could exit
/// between the initial status check and the process source's registration, leaving
/// a zombie and a caller waiting forever (seen in clistate-probe on a real Mac).
@Suite struct ProcessExitRaceTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test func manyShortLivedProcessesAllComplete() async throws {
        let runner = ProcessCommandRunner()
        let environment = ExecutionEnvironment(variables: ["PATH": "/usr/bin:/bin"])
        let command = Command(executable: "/usr/bin/true", timeout: .seconds(5))
        let workers = 24
        let perWorker = 60
        let completed = Counter()

        // Unstructured on purpose: a hung run must not keep the test from failing.
        for _ in 0..<workers {
            Task.detached {
                for _ in 0..<perWorker {
                    guard let result = try? await runner.run(command, environment: environment), result.exitCode == 0 else { continue }
                    completed.increment()
                }
            }
        }

        let total = workers * perWorker
        let deadline = ContinuousClock.now + .seconds(60)
        while completed.count < total, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(completed.count == total, "\(total - completed.count) runs never finished: a child's exit was not observed")
    }
}
