import CLIStateDomain
import Foundation

/// Python applications installed with `pipx install`, one venv each.
public struct PipxProvider: ToolUpdateProvider, ToolUninstallProvider {
    public let id: ProviderID = .pipx

    private let fileSystem: any FileSystem
    private let invoker: CommandInvoker

    public init(runner: any CommandRunning, fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
        self.invoker = CommandInvoker(providerID: .pipx, runner: runner)
    }

    static func command(_ executable: String, _ arguments: [String], timeout: Duration? = nil) -> Command {
        Command(executable: executable, arguments: arguments, timeout: timeout)
    }

    // MARK: ToolProvider

    public func availability(context: ProviderContext) async -> ProviderAvailability {
        guard let pipx = context.resolveExecutable("pipx") else {
            return .unavailable(id, reason: "executableNotFound")
        }
        do {
            let result = try await invoker.runChecked(Self.command(pipx, ["--version"], timeout: ScanTimeout.fast), context: context)
            return ProviderAvailability(providerID: id, isAvailable: true, executable: pipx, version: OutputText.firstLine(result.stdoutString))
        } catch {
            return ProviderAvailability(providerID: id, isAvailable: false, executable: pipx, reason: "versionCommandFailed")
        }
    }

    /// Fast and deep scans are identical: pipx has no outdated command, so
    /// `latestVersion` stays `nil`.
    public func scan(context: ProviderContext, depth: ScanDepth) async throws -> ProviderInventory {
        let pipx = try context.requireExecutable("pipx", provider: id)
        let fast = ScanTimeout.fast
        let listCommand = Self.command(pipx, ["list", "--json"], timeout: fast)

        async let versionResult = invoker.run(Self.command(pipx, ["--version"], timeout: fast), context: context)
        async let listResult = invoker.run(listCommand, context: context)
        async let venvsResult = invoker.run(Self.command(pipx, ["environment", "--value", "PIPX_LOCAL_VENVS"], timeout: fast), context: context)
        async let binDirResult = invoker.run(Self.command(pipx, ["environment", "--value", "PIPX_BIN_DIR"], timeout: fast), context: context)

        let (version, list, venvs, binDir) = try await (versionResult, listResult, venvsResult, binDirResult)
        var warnings: [String] = []
        for result in [version, list, venvs, binDir] {
            warnings += OutputText.warnings(fromStderr: result.stderrString).filter { !Self.isEmptyNotice($0) }
        }

        // `pipx list` exits 1 when some venvs have problems but still prints JSON.
        let listDTO: PipxListDTO
        do {
            listDTO = try JSONDecoder().decode(PipxListDTO.self, from: list.stdout)
        } catch {
            if !list.succeeded { throw invoker.failure(listCommand, list) }
            throw ProviderError.parsingFailed(id, what: "pipx list --json")
        }

        let venvsRoot = venvs.succeeded ? OutputPath.absolute(venvs.stdoutString) : nil
        let binDirectory = binDir.succeeded ? OutputPath.absolute(binDir.stdoutString) : nil
        let tools = listDTO.venvs.keys.sorted().compactMap { name -> ProviderTool? in
            guard let venv = listDTO.venvs[name] else { return nil }
            return PipxMapper.tool(name: name, venv: venv, venvsRoot: venvsRoot)
        }

        let pipxVersion = version.succeeded ? OutputText.firstLine(version.stdoutString) : nil
        return ProviderInventory(
            providerID: id,
            availability: ProviderAvailability(providerID: id, isAvailable: true, executable: pipx, version: pipxVersion),
            layout: PipxMapper.layout(venvs: venvsRoot, binDir: binDirectory),
            tools: tools,
            depth: depth,
            scannedAt: context.now,
            warnings: warnings.uniquedPreservingOrder()
        )
    }

    /// "nothing has been installed with pipx 😴" is an empty inventory, not a problem.
    private static func isEmptyNotice(_ warning: String) -> Bool {
        warning.lowercased().hasPrefix("nothing has been installed with pipx")
    }

    // MARK: Plans

    /// One `pipx upgrade <name>` per venv. Pinned venvs are refused: pipx would
    /// skip them and report success.
    public func updatePlan(for tools: [ProviderTool], context: ProviderContext) throws -> OperationPlan {
        let pipx = try context.requireExecutable("pipx", provider: id)
        let tools = try validatedTools(tools)
        guard tools.allSatisfy({ !$0.isPinned }) else { throw ProviderError.unsupportedOperation }
        return OperationPlan(
            kind: .update,
            providerID: id,
            targets: tools.map(\.operationTarget),
            commands: tools.map(\.packageName).uniquedPreservingOrder().map { Self.command(pipx, ["upgrade", $0]) },
            requiresNetwork: true
        )
    }

    public func uninstallPlan(for tool: ProviderTool, context: ProviderContext) throws -> OperationPlan {
        let pipx = try context.requireExecutable("pipx", provider: id)
        let tool = try validatedTools([tool])[0]
        return OperationPlan(
            kind: .uninstall,
            providerID: id,
            targets: [tool.operationTarget],
            commands: [Self.command(pipx, ["uninstall", tool.packageName])],
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
}
