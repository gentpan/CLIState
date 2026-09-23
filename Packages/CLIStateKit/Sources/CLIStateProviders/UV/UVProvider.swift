import CLIStateDomain
import Foundation

/// Tools installed with `uv tool install`.
public struct UVProvider: ToolUpdateProvider, ToolUninstallProvider, CleanupProvider {
    public let id: ProviderID = .uv

    private let fileSystem: any FileSystem
    private let invoker: CommandInvoker

    public init(runner: any CommandRunning, fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
        self.invoker = CommandInvoker(providerID: .uv, runner: runner)
    }

    static func command(_ executable: String, _ arguments: [String], timeout: Duration? = nil) -> Command {
        Command(executable: executable, arguments: arguments, timeout: timeout)
    }

    // MARK: ToolProvider

    public func availability(context: ProviderContext) async -> ProviderAvailability {
        guard let uv = context.resolveExecutable("uv") else {
            return .unavailable(id, reason: "executableNotFound")
        }
        do {
            let result = try await invoker.runChecked(Self.command(uv, ["--version"], timeout: ScanTimeout.fast), context: context)
            return ProviderAvailability(providerID: id, isAvailable: true, executable: uv, version: UVToolListParser.version(from: result.stdoutString))
        } catch {
            return ProviderAvailability(providerID: id, isAvailable: false, executable: uv, reason: "versionCommandFailed")
        }
    }

    public func scan(context: ProviderContext, depth: ScanDepth) async throws -> ProviderInventory {
        let uv = try context.requireExecutable("uv", provider: id)
        let fast = ScanTimeout.fast
        let listCommand = Self.command(uv, ["tool", "list", "--show-paths"], timeout: fast)

        async let versionResult = invoker.run(Self.command(uv, ["--version"], timeout: fast), context: context)
        async let toolDirResult = invoker.run(Self.command(uv, ["tool", "dir"], timeout: fast), context: context)
        async let binDirResult = invoker.run(Self.command(uv, ["tool", "dir", "--bin"], timeout: fast), context: context)
        async let listResult = invoker.run(listCommand, context: context)
        async let outdatedResult: CommandResult? = depth == .deep
            ? invoker.run(Self.command(uv, ["tool", "list", "--outdated"], timeout: ScanTimeout.deep), context: context)
            : nil

        let (version, toolDir, binDir, list, outdated) = try await (versionResult, toolDirResult, binDirResult, listResult, outdatedResult)
        var warnings: [String] = []
        for result in [version, toolDir, binDir, list] + [outdated].compactMap({ $0 }) {
            warnings += OutputText.warnings(fromStderr: result.stderrString)
        }
        guard list.succeeded else { throw invoker.failure(listCommand, list) }

        var layout = ProviderLayout()
        let toolDirectory = toolDir.succeeded ? OutputText.firstLine(toolDir.stdoutString) : nil
        layout[.uvToolDir] = toolDirectory
        layout[.uvToolBinDir] = binDir.succeeded ? OutputText.firstLine(binDir.stdoutString) : nil

        var latest: [String: String]?
        if let outdated {
            if outdated.succeeded {
                latest = Dictionary(
                    UVToolListParser.parse(outdated.stdoutString).compactMap { entry in entry.latestVersion.map { (entry.name, $0) } },
                    uniquingKeysWith: { first, _ in first }
                )
            } else {
                warnings.append("uv tool list --outdated failed (exit \(outdated.exitCode))")
            }
        }

        let tools = UVToolListParser.parse(list.stdoutString).map { entry in
            let latestVersion = latest?[entry.name]
            return ProviderTool(
                providerID: id,
                packageName: entry.name,
                kind: .tool,
                installedVersions: entry.version.map { [$0] } ?? [],
                activeVersion: entry.version,
                latestVersion: latestVersion,
                isOutdated: latest.map { _ in latestVersion != nil },
                installPrefix: entry.path ?? toolDirectory.map { "\($0)/\(entry.name)" },
                executableNames: entry.executables.map(\.name),
                executablePaths: entry.executables.compactMap(\.path),
                isDirect: true
            )
        }

        let uvVersion = version.succeeded ? UVToolListParser.version(from: version.stdoutString) : nil
        return ProviderInventory(
            providerID: id,
            availability: ProviderAvailability(providerID: id, isAvailable: true, executable: uv, version: uvVersion),
            layout: layout,
            tools: tools,
            depth: depth,
            scannedAt: context.now,
            warnings: warnings.uniquedPreservingOrder()
        )
    }

    // MARK: Plans

    public func updatePlan(for tools: [ProviderTool], context: ProviderContext) throws -> OperationPlan {
        let uv = try context.requireExecutable("uv", provider: id)
        let tools = try validatedTools(tools)
        return OperationPlan(
            kind: .update,
            providerID: id,
            targets: tools.map(\.operationTarget),
            commands: [Self.command(uv, ["tool", "upgrade"] + tools.map(\.packageName).uniquedPreservingOrder())],
            requiresNetwork: true
        )
    }

    public func uninstallPlan(for tool: ProviderTool, context: ProviderContext) throws -> OperationPlan {
        let uv = try context.requireExecutable("uv", provider: id)
        let tool = try validatedTools([tool])[0]
        return OperationPlan(
            kind: .uninstall,
            providerID: id,
            targets: [tool.operationTarget],
            commands: [Self.command(uv, ["tool", "uninstall", tool.packageName])],
            requiresNetwork: false
        )
    }

    /// `uv cache prune`: removes only unreachable cache entries.
    public func cleanupPlan(context: ProviderContext) throws -> OperationPlan {
        let uv = try context.requireExecutable("uv", provider: id)
        return OperationPlan(
            kind: .cleanup(.providerCache),
            providerID: id,
            targets: [],
            commands: [Self.command(uv, ["cache", "prune"])],
            requiresNetwork: false
        )
    }

    private func validatedTools(_ tools: [ProviderTool]) throws -> [ProviderTool] {
        guard !tools.isEmpty else { throw ProviderError.unsupportedOperation }
        for tool in tools {
            guard tool.providerID == id, tool.kind == .tool else { throw ProviderError.unsupportedOperation }
            try PackageNameValidator.validate(tool.packageName)
        }
        return tools.uniquedByInstallation()
    }

    // MARK: Cleanup

    /// `uv cache prune` has no dry run (uv 0.11.8), so the preview is the size of
    /// the whole cache directory: an upper bound of what pruning frees.
    public func cleanupCandidates(context: ProviderContext) async throws -> [CleanupCandidate] {
        let uv = try context.requireExecutable("uv", provider: id)
        let cacheResult = try await invoker.runChecked(Self.command(uv, ["cache", "dir"], timeout: ScanTimeout.fast), context: context)
        guard let cacheDirectory = OutputText.firstLine(cacheResult.stdoutString), cacheDirectory.hasPrefix("/") else {
            throw ProviderError.parsingFailed(id, what: "uv cache dir")
        }
        guard fileSystem.isDirectory(atPath: cacheDirectory) else { return [] }

        let usage = try? await invoker.run(DiskUsage.command(path: cacheDirectory), context: context)
        let bytes = usage.flatMap { $0.succeeded ? DiskUsage.parseBytes($0.stdoutString) : nil }
        return [CleanupCandidate(
            kind: .providerCache,
            providerID: id,
            risk: .low,
            paths: [cacheDirectory],
            reclaimableBytes: bytes,
            plan: try cleanupPlan(context: context)
        )]
    }
}
