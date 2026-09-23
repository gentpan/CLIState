import CLIStateDomain
import Foundation

/// Global packages of the pnpm the user's shell resolves.
public struct PNPMProvider: ToolUpdateProvider, ToolUninstallProvider, CleanupProvider, OperationPreflightProvider {
    public let id: ProviderID = .pnpm

    private let fileSystem: any FileSystem
    private let invoker: CommandInvoker

    public init(runner: any CommandRunning, fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
        self.invoker = CommandInvoker(providerID: .pnpm, runner: runner)
    }

    static func command(_ executable: String, _ arguments: [String], timeout: Duration? = nil) -> Command {
        Command(executable: executable, arguments: arguments, timeout: timeout)
    }

    // MARK: ToolProvider

    public func availability(context: ProviderContext) async -> ProviderAvailability {
        guard let pnpm = context.resolveExecutable("pnpm") else {
            return .unavailable(id, reason: "executableNotFound")
        }
        do {
            let result = try await invoker.runChecked(Self.command(pnpm, ["--version"], timeout: ScanTimeout.fast), context: context)
            return ProviderAvailability(providerID: id, isAvailable: true, executable: pnpm, version: OutputText.firstLine(result.stdoutString))
        } catch {
            return ProviderAvailability(providerID: id, isAvailable: false, executable: pnpm, reason: "versionCommandFailed")
        }
    }

    public func scan(context: ProviderContext, depth: ScanDepth) async throws -> ProviderInventory {
        let pnpm = try context.requireExecutable("pnpm", provider: id)
        let fast = ScanTimeout.fast
        let rootCommand = Self.command(pnpm, ["root", "-g"], timeout: fast)
        let listCommand = Self.command(pnpm, ["list", "-g", "--depth=0", "--json"], timeout: fast)

        async let versionResult = invoker.run(Self.command(pnpm, ["--version"], timeout: fast), context: context)
        async let rootResult = invoker.run(rootCommand, context: context)
        // Prints nothing (exit 0) when PNPM_HOME is not set up.
        async let binResult = invoker.run(Self.command(pnpm, ["bin", "-g"], timeout: fast), context: context)
        async let listResult = invoker.run(listCommand, context: context)

        let (version, rootOutput, binOutput, list) = try await (versionResult, rootResult, binResult, listResult)
        var warnings: [String] = []
        for result in [version, rootOutput, binOutput, list] {
            warnings += OutputText.warnings(fromStderr: result.stderrString)
        }

        guard rootOutput.succeeded else { throw invoker.failure(rootCommand, rootOutput) }
        guard let root = OutputPath.absolute(rootOutput.stdoutString) else {
            throw ProviderError.parsingFailed(id, what: "pnpm root -g")
        }
        let globalBin = binOutput.succeeded ? OutputPath.absolute(binOutput.stdoutString) : nil

        let listDTO: PNPMListDTO
        do {
            listDTO = try JSONDecoder().decode(PNPMListDTO.self, from: list.stdout)
        } catch {
            if !list.succeeded { throw invoker.failure(listCommand, list) }
            throw ProviderError.parsingFailed(id, what: "pnpm list -g --depth=0 --json")
        }
        let dependencies = listDTO.dependencies

        // With nothing installed the global directory has no package.json and
        // `pnpm outdated -g` fails, so only ask when there is something to check.
        var outdatedPackages: [String: PNPMOutdatedDTO.Entry]?
        if depth == .deep, !dependencies.isEmpty {
            let outdated = try await invoker.run(Self.command(pnpm, ["outdated", "-g", "--format", "json"], timeout: ScanTimeout.deep), context: context)
            warnings += OutputText.warnings(fromStderr: outdated.stderrString)
            let text = outdated.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            // Exits 1 whenever something is outdated; valid JSON is success.
            if outdated.termination == .exited, text.isEmpty, outdated.exitCode == 0 {
                outdatedPackages = [:]
            } else if outdated.termination == .exited, let dto = try? JSONDecoder().decode(PNPMOutdatedDTO.self, from: outdated.stdout) {
                outdatedPackages = dto.packages
            } else {
                warnings.append("pnpm outdated -g --format json failed (exit \(outdated.exitCode))")
            }
        }

        let tools = dependencies.keys.sorted().compactMap { name -> ProviderTool? in
            guard let dependency = dependencies[name] else { return nil }
            return PNPMMapper.tool(
                name: name,
                dependency: dependency,
                packageJSON: readPackageJSON(root: root, name: name, dependency: dependency),
                root: root,
                globalBin: globalBin,
                outdated: outdatedPackages
            )
        }

        let pnpmVersion = version.succeeded ? OutputText.firstLine(version.stdoutString) : nil
        return ProviderInventory(
            providerID: id,
            availability: ProviderAvailability(providerID: id, isAvailable: true, executable: pnpm, version: pnpmVersion),
            layout: PNPMMapper.layout(root: root, globalBin: globalBin),
            tools: tools,
            depth: depth,
            scannedAt: context.now,
            warnings: warnings.uniquedPreservingOrder()
        )
    }

    /// Prefers the virtual-store directory pnpm reports; `<root>/<name>` is a
    /// symlink to the same place.
    private func readPackageJSON(root: String, name: String, dependency: PNPMListDTO.Dependency) -> NPMPackageJSONDTO? {
        var directories = ["\(root)/\(name)"]
        if let path = dependency.path, path.hasPrefix("/") { directories.insert(path, at: 0) }
        for directory in directories {
            if let data = try? fileSystem.readData(atPath: "\(directory)/package.json", maxBytes: NPMProvider.packageJSONByteLimit),
               let dto = try? JSONDecoder().decode(NPMPackageJSONDTO.self, from: data) {
                return dto
            }
        }
        return nil
    }

    // MARK: Plans

    /// Linked (`pnpm link -g`) packages are refused.
    public func updatePlan(for tools: [ProviderTool], context: ProviderContext) throws -> OperationPlan {
        let pnpm = try context.requireExecutable("pnpm", provider: id)
        let tools = try validatedTools(tools)
        guard tools.allSatisfy({ !$0.isPinned }) else { throw ProviderError.unsupportedOperation }
        let specs = tools.map(\.packageName).uniquedPreservingOrder().map { "\($0)@latest" }
        return OperationPlan(
            kind: .update,
            providerID: id,
            targets: tools.map(\.operationTarget),
            commands: [Self.command(pnpm, ["add", "-g"] + specs)],
            requiresNetwork: true
        )
    }

    public func uninstallPlan(for tool: ProviderTool, context: ProviderContext) throws -> OperationPlan {
        let pnpm = try context.requireExecutable("pnpm", provider: id)
        let tool = try validatedTools([tool])[0]
        return OperationPlan(
            kind: .uninstall,
            providerID: id,
            targets: [tool.operationTarget],
            commands: [Self.command(pnpm, ["remove", "-g", tool.packageName])],
            requiresNetwork: false
        )
    }

    // MARK: Preflight

    /// `pnpm add -g` (update and install) / `pnpm remove -g` fail with ERR_PNPM_NO_GLOBAL_BIN_DIR unless
    /// PNPM_HOME (set up by `pnpm setup`) points at a global bin directory. Catch it
    /// before running instead of surfacing a cryptic pnpm error afterwards.
    public func preflight(for plan: OperationPlan, context: ProviderContext) async -> [PreflightCheck] {
        guard plan.kind == .update || plan.kind == .uninstall || plan.kind == .install else { return [] }
        let home = context.execution.variables["PNPM_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        guard let home else {
            return [PreflightCheck(kind: .writableLocation, outcome: .failed, detail: "PNPM_HOME is not set — run `pnpm setup` in Terminal, then open a new window")]
        }
        guard fileSystem.isDirectory(atPath: home) else {
            return [PreflightCheck(kind: .writableLocation, outcome: .failed, detail: "PNPM_HOME (\(home)) does not exist — run `pnpm setup` in Terminal")]
        }
        return [PreflightCheck(kind: .writableLocation, outcome: fileSystem.isWritable(atPath: home) ? .passed : .failed, detail: home)]
    }

    /// `pnpm store prune`: removes packages no project references any more.
    public func cleanupPlan(context: ProviderContext) throws -> OperationPlan {
        let pnpm = try context.requireExecutable("pnpm", provider: id)
        return OperationPlan(
            kind: .cleanup(.providerCache),
            providerID: id,
            targets: [],
            commands: [Self.command(pnpm, ["store", "prune"])],
            requiresNetwork: false
        )
    }

    private func validatedTools(_ tools: [ProviderTool]) throws -> [ProviderTool] {
        guard !tools.isEmpty else { throw ProviderError.unsupportedOperation }
        for tool in tools {
            guard tool.providerID == id, tool.kind == .globalPackage else { throw ProviderError.unsupportedOperation }
            try PackageNameValidator.validate(tool.packageName)
        }
        return tools.uniquedByInstallation()
    }

    // MARK: Cleanup

    /// `pnpm store prune` has no dry run, so the preview is the size of the
    /// whole store: an upper bound of what pruning frees.
    public func cleanupCandidates(context: ProviderContext) async throws -> [CleanupCandidate] {
        let pnpm = try context.requireExecutable("pnpm", provider: id)
        let storeResult = try await invoker.runChecked(Self.command(pnpm, ["store", "path"], timeout: ScanTimeout.fast), context: context)
        guard let store = OutputPath.absolute(storeResult.stdoutString) else {
            throw ProviderError.parsingFailed(id, what: "pnpm store path")
        }
        guard fileSystem.isDirectory(atPath: store) else { return [] }

        let usage = try? await invoker.run(DiskUsage.command(path: store), context: context)
        let bytes = usage.flatMap { $0.succeeded ? DiskUsage.parseBytes($0.stdoutString) : nil }
        return [CleanupCandidate(
            kind: .providerCache,
            providerID: id,
            risk: .low,
            paths: [store],
            reclaimableBytes: bytes,
            plan: try cleanupPlan(context: context)
        )]
    }
}
