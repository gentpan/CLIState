import CLIStateDomain
import CLIStateInfrastructure
import Foundation

extension CommandScheduler: MutationLocking {
    public func withMutationLock<T: Sendable>(scope: String, _ body: @Sendable () async throws -> T) async throws -> T {
        try await withMutationLock(scope: scope, isolation: nil, body)
    }
}

extension LocalTrash: Trashing {
    public func moveToTrash(path: String) throws {
        _ = try moveToTrash(atPath: path)
    }
}
