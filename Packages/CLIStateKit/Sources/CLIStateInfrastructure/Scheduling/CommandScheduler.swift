/// Admission control for external commands (§89–§91): read commands share a
/// bounded pool, mutations run one at a time per scope (usually the provider ID).
///
///     let inventory = try await scheduler.withReadPermit { try await runner.run(list, environment: env) }
///     try await scheduler.withMutationLock(scope: plan.mutationScope) { … }
public actor CommandScheduler {
    public static let defaultReadLimit = 6

    public nonisolated let maxConcurrentReads: Int

    enum Lane: Hashable, Sendable {
        case read
        case mutation(String)
    }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Pool {
        let limit: Int
        var active = 0
        var waiters: [Waiter] = []
    }

    private var pools: [Lane: Pool] = [:]
    private var nextWaiterID: UInt64 = 0

    public init(maxConcurrentReads: Int = CommandScheduler.defaultReadLimit) {
        precondition(maxConcurrentReads > 0, "maxConcurrentReads must be positive")
        self.maxConcurrentReads = maxConcurrentReads
    }

    /// Runs `body` once one of the `maxConcurrentReads` permits is free. Waiters are
    /// served first-in first-out; a waiter whose task is cancelled leaves the queue
    /// and throws `CancellationError` without taking a permit.
    public func withReadPermit<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async throws -> T {
        try await withPermit(.read, body)
    }

    /// Runs `body` exclusively within `scope`; different scopes run in parallel.
    public func withMutationLock<T>(
        scope: String,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async throws -> T {
        try await withPermit(.mutation(scope), body)
    }

    private func withPermit<T>(
        _ lane: Lane,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async throws -> T {
        try await acquire(lane)
        do {
            let value = try await body()
            await release(lane)
            return value
        } catch {
            await release(lane)
            throw error
        }
    }

    // MARK: Pool bookkeeping

    private func limit(for lane: Lane) -> Int {
        switch lane {
        case .read: maxConcurrentReads
        case .mutation: 1
        }
    }

    private func acquire(_ lane: Lane) async throws {
        try Task.checkCancellation()
        var pool = pools[lane] ?? Pool(limit: limit(for: lane))
        if pool.active < pool.limit, pool.waiters.isEmpty {
            pool.active += 1
            pools[lane] = pool
            return
        }

        nextWaiterID += 1
        let id = nextWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                pools[lane, default: Pool(limit: limit(for: lane))].waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            // Runs after the waiter is enqueued: the hop onto this actor can only
            // happen once `acquire` has suspended.
            Task { await self.cancelWaiter(id, in: lane) }
        }
    }

    private func release(_ lane: Lane) {
        guard var pool = pools[lane] else { return }
        if pool.waiters.isEmpty {
            pool.active -= 1
            store(pool, for: lane)
        } else {
            // Hand the permit straight to the oldest waiter so newcomers can't barge.
            let next = pool.waiters.removeFirst()
            pools[lane] = pool
            next.continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UInt64, in lane: Lane) {
        // Not found means the permit was already handed over; the body will see
        // the cancellation itself and release normally.
        guard var pool = pools[lane], let index = pool.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = pool.waiters.remove(at: index)
        store(pool, for: lane)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func store(_ pool: Pool, for lane: Lane) {
        if case .mutation = lane, pool.active == 0, pool.waiters.isEmpty {
            pools[lane] = nil
        } else {
            pools[lane] = pool
        }
    }

    // MARK: Introspection for tests

    func activeCount(_ lane: Lane) -> Int { pools[lane]?.active ?? 0 }
    func waitingCount(_ lane: Lane) -> Int { pools[lane]?.waiters.count ?? 0 }
}
