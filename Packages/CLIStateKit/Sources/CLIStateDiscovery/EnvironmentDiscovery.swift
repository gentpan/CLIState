import CLIStateDomain
import Foundation

/// Milestone 1 pipeline: login shell → PATH entries → binary inventory.
public struct EnvironmentDiscovery: EnvironmentDiscovering {
    private let runner: CommandRunning
    private let fileSystem: FileSystem
    private let shadowCandidates: [String]
    private let hostContext: @Sendable () -> HostContext
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - shadowCandidates: Registry command names checked for alias/function
    ///     shadowing. Unsafe names are dropped, never passed to the shell.
    ///   - hostContext: The app's own user info and environment; read once per `discover()`.
    public init(
        runner: CommandRunning,
        fileSystem: FileSystem,
        shadowCandidates: [String],
        hostContext: @escaping @Sendable () -> HostContext = { HostContext.current() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.fileSystem = fileSystem
        self.shadowCandidates = shadowCandidates
        self.hostContext = hostContext
        self.now = now
    }

    public func discover() async throws -> DiscoveryResult {
        let context = hostContext()
        let shell = ShellDetector(context: context, fileSystem: fileSystem).detect()
        let session = try await ShellEnvironmentLoader(runner: runner, context: context, now: now)
            .load(shell: shell, shadowCandidates: shadowCandidates)
        try Task.checkCancellation()

        let (entries, listings) = PATHResolver(fileSystem: fileSystem)
            .resolveWithListings(path: session.environment.path, variables: session.execution.variables)
        let inventory = await BinaryScanner(fileSystem: fileSystem).scan(entries, listings: listings)
        try Task.checkCancellation()

        return DiscoveryResult(
            session: session,
            pathEntries: BinaryScanner.annotate(entries, with: inventory),
            binaries: inventory
        )
    }
}
