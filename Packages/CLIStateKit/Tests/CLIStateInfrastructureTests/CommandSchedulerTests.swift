@testable import CLIStateInfrastructure
import Foundation
import Testing

private actor ConcurrencyProbe {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var order: [String] = []
    private(set) var flags: Set<String> = []

    func enter(_ label: String = "") {
        current += 1
        peak = max(peak, current)
        order.append(label)
    }

    func leave() { current -= 1 }

    func raise(_ flag: String) { flags.insert(flag) }
    func isRaised(_ flag: String) -> Bool { flags.contains(flag) }
}

@Suite struct CommandSchedulerTests {
    @Test func readPermitsCapConcurrency() async throws {
        let scheduler = CommandScheduler(maxConcurrentReads: 2)
        let probe = ConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await scheduler.withReadPermit {
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(30))
                        await probe.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await probe.peak == 2)
        #expect(await scheduler.activeCount(.read) == 0)
    }

    @Test func defaultReadLimitIsSix() {
        #expect(CommandScheduler().maxConcurrentReads == 6)
    }

    @Test func waitersAreServedInOrderAndCancelledWaitersLeaveTheQueue() async throws {
        let scheduler = CommandScheduler(maxConcurrentReads: 1)
        let probe = ConcurrencyProbe()
        let (gate, openGate) = AsyncStream.makeStream(of: Void.self)

        let holder = Task {
            try await scheduler.withReadPermit {
                for await _ in gate { break }
            }
        }
        #expect(await waitUntil { await scheduler.activeCount(.read) == 1 })

        var waiters: [Task<Void, any Error>] = []
        for label in ["w1", "w2", "w3"] {
            waiters.append(Task { try await scheduler.withReadPermit { await probe.enter(label) } })
            let expected = waiters.count
            #expect(await waitUntil { await scheduler.waitingCount(.read) == expected })
        }

        waiters[1].cancel()
        await #expect(throws: CancellationError.self) { try await waiters[1].value }
        #expect(await scheduler.waitingCount(.read) == 2)

        openGate.yield()
        openGate.finish()
        try await holder.value
        try await waiters[0].value
        try await waiters[2].value

        #expect(await probe.order == ["w1", "w3"])
        #expect(await scheduler.activeCount(.read) == 0)
        #expect(await scheduler.waitingCount(.read) == 0)
    }

    @Test func permitIsReleasedWhenBodyThrows() async throws {
        struct Boom: Error {}
        let scheduler = CommandScheduler(maxConcurrentReads: 1)
        await #expect(throws: Boom.self) {
            try await scheduler.withReadPermit { throw Boom() }
        }
        #expect(await scheduler.activeCount(.read) == 0)
        let value = try await scheduler.withReadPermit { 42 }
        #expect(value == 42)
    }

    @Test func mutationsSerializeWithinScope() async throws {
        let scheduler = CommandScheduler()
        let probe = ConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await scheduler.withMutationLock(scope: "homebrew") {
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        await probe.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await probe.peak == 1)
        #expect(await scheduler.activeCount(.mutation("homebrew")) == 0)
    }

    @Test func differentScopesRunInParallel() async throws {
        let scheduler = CommandScheduler()
        let probe = ConcurrencyProbe()

        // Homebrew holds its lock until it sees npm inside its own lock; if scopes
        // were serialized globally this would time out and return false.
        async let homebrewSawNpm = scheduler.withMutationLock(scope: "homebrew") {
            await probe.raise("homebrew")
            return await waitUntil { await probe.isRaised("npm") }
        }
        #expect(await waitUntil { await probe.isRaised("homebrew") })
        try await scheduler.withMutationLock(scope: "npm") {
            await probe.raise("npm")
        }
        #expect(try await homebrewSawNpm)
    }

    @Test func cancelledMutationWaiterDoesNotBlockScope() async throws {
        let scheduler = CommandScheduler()
        let (gate, openGate) = AsyncStream.makeStream(of: Void.self)
        let holder = Task {
            try await scheduler.withMutationLock(scope: "npm") {
                for await _ in gate { break }
            }
        }
        #expect(await waitUntil { await scheduler.activeCount(.mutation("npm")) == 1 })

        let waiter = Task { try await scheduler.withMutationLock(scope: "npm") {} }
        #expect(await waitUntil { await scheduler.waitingCount(.mutation("npm")) == 1 })
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }

        openGate.yield()
        openGate.finish()
        try await holder.value
        try await scheduler.withMutationLock(scope: "npm") {}
        #expect(await scheduler.activeCount(.mutation("npm")) == 0)
    }
}
