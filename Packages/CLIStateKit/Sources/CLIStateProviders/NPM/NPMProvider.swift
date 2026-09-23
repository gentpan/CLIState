import CLIStateDomain
import Foundation

/// Global packages of the npm the user's shell resolves (the active instance, §157).
public struct NPMProvider: ToolUpdateProvider, ToolUninstallProvider, CleanupProvider {
    public let id: ProviderID = .npm

    /// `package.json` files are small; anything larger is not worth reading.
    static let packageJSONByteLimit = 1 << 20

    private let fileSystem: any FileSystem
    private let invoker: CommandInvoker

    public init(runner: any CommandRunning, fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
        self.invoker = CommandInvoker(providerID: .npm, runner: runner)
    }

    static func command(_ executable: String, _ arguments: [String], timeout: Duration? = nil) -> Command {
        Command(executable: executable, arguments: arguments, timeout: timeout)
    }

    // MARK: ToolProvider

    public func availability(context: ProviderContext) async -> ProviderAvailability {
        guard let npm = context.resolveExecutable("npm") else {
            return .unavailable(id, reason: "executableNotFound")
        }
        do {
            let result = try await invoker.runChecked(Self.command(npm, ["--version"], timeout: ScanTimeout.fast), context: context)
            return ProviderAvailability(providerID: id, isAvailable: true, executable: npm, version: OutputText.firstLine(result.stdoutString))
        } catch {
            return ProviderAvailability(providerID: id, isAvailable: false, executable: npm, reason: "versionCommandFailed")
        }
    }

    public func scan(context: ProviderContext, depth: ScanDepth) async throws -> ProviderInventory {
        let npm = try context.requireExecutable("npm", provider: id)
        let fast = ScanTimeout.fast
        let rootCommand = Self.command(npm, ["root", "-g"], timeout: fast)
        let listCommand = Self.command(npm, ["list", "-g", "--depth=0", "--json"], timeout: fast)

        async let versionResult = invoker.run(Self.command(npm, ["--version"], timeout: fast), context: context)
        async let rootResult = invoker.run(rootCommand, context: context)
        async let prefixResult = invoker.run(Self.command(npm, ["prefix", "-g"], timeout: fast), context: context)
        async let listResult = invoker.run(listCommand, context: context)
        async let outdatedResult: CommandResult? = depth == .deep
            ? invoker.run(Self.command(npm, ["outdated", "-g", "--json"], timeout: ScanTimeout.deep), context: context)
            : nil

        let (version, rootOutput, prefixOutput, list, outdated) = try await (versionResult, rootResult, prefixResult, listResult, outdatedResult)
        var warnings: [String] = []
        for result in [version, rootOutput, prefixOutput, list] + [outdated].compactMap({ $0 }) {
            warnings += OutputText.warnings(fromStderr: result.stderrString)
        }

        guard rootOutput.succeeded else { throw invoker.failure(rootCommand, rootOutput) }
        guard let root = OutputText.firstLine(rootOutput.stdoutString), root.hasPrefix("/") else {
            throw ProviderError.parsingFailed(id, what: "npm root -g")
        }
        let prefix = prefixOutput.succeeded ? OutputText.firstLine(prefixOutput.stdoutString).flatMap { $0.hasPrefix("/") ? $0 : nil } : nil

        // `npm list` exits 1 for extraneous or invalid trees but still prints the tree.
        let listDTO: NPMListDTO
        do {
            listDTO = try JSONDecoder().decode(NPMListDTO.self, from: list.stdout)
        } catch {
            if !list.succeeded { throw invoker.failure(listCommand, list) }
            throw ProviderError.parsingFailed(id, what: "npm list -g --depth=0 --json")
        }

        // `npm outdated` exits 1 whenever something is outdated; valid JSON is success.
        var outdatedPackages: [String: NPMOutdatedDTO.Entry]?
        if let outdated {
            let text = outdated.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if outdated.termination == .exited, text.isEmpty, outdated.exitCode == 0 {
                outdatedPackages = [:]
            } else if outdated.termination == .exited, let dto = try? JSONDecoder().decode(NPMOutdatedDTO.self, from: outdated.stdout) {
                outdatedPackages = dto.packages
            } else {
                warnings.append("npm outdated -g --json failed (exit \(outdated.exitCode))")
            }
        }

        let instanceID = NPMMapper.instanceID(root: root)
        let tools = listDTO.dependencies.keys.sorted().compactMap { name -> ProviderTool? in
            guard let dependency = listDTO.dependencies[name], dependency.missing != true else { return nil }
            return NPMMapper.tool(
                name: name,
                dependency: dependency,
                packageJSON: readPackageJSON(root: root, name: name),
                root: root,
                instanceID: instanceID,
                outdated: outdatedPackages
            )
        }

        let npmVersion = version.succeeded ? OutputText.firstLine(version.stdoutString) : nil
        let instance = ProviderInstance(
            id: instanceID,
            providerID: id,
            executable: npm,
            version: npmVersion,
            context: NPMMapper.environmentContext(
                npmRealPath: fileSystem.resolvingSymlinks(atPath: npm) ?? npm,
                homebrewPrefix: context.resolveExecutable("brew").map { (($0 as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent },
                fileSystem: fileSystem
            )
        )
        return ProviderInventory(
            providerID: id,
            availability: ProviderAvailability(providerID: id, isAvailable: true, executable: npm, version: npmVersion),
            instance: instance,
            layout: NPMMapper.layout(root: root, prefix: prefix),
            tools: tools,
            depth: depth,
            scannedAt: context.now,
            warnings: warnings.uniquedPreservingOrder()
        )
    }

    private func readPackageJSON(root: String, name: String) -> NPMPackageJSONDTO? {
        guard let data = try? fileSystem.readData(atPath: "\(root)/\(name)/package.json", maxBytes: Self.packageJSONByteLimit) else { return nil }
        return try? JSONDecoder().decode(NPMPackageJSONDTO.self, from: data)
    }

    // MARK: Plans

    public func updatePlan(for tools: [ProviderTool], context: ProviderContext) throws -> OperationPlan {
        let npm = try context.requireExecutable("npm", provider: id)
        let tools = try validatedTools(tools)
        let specs = tools.map(\.packageName).uniquedPreservingOrder().map { "\($0)@latest" }
        return OperationPlan(
            kind: .update,
            providerID: id,
            targets: tools.map(\.operationTarget),
            commands: [Self.command(npm, ["install", "-g"] + specs)],
            requiresNetwork: true
        )
    }

    public func uninstallPlan(for tool: ProviderTool, context: ProviderContext) throws -> OperationPlan {
        let npm = try context.requireExecutable("npm", provider: id)
        let tool = try validatedTools([tool])[0]
        return OperationPlan(
            kind: .uninstall,
            providerID: id,
            targets: [tool.operationTarget],
            commands: [Self.command(npm, ["uninstall", "-g", tool.packageName])],
            requiresNetwork: false
        )
    }

    /// Only `.providerCache` → `npm cache clean --force`.
    public func cleanupPlan(context: ProviderContext) throws -> OperationPlan {
        let npm = try context.requireExecutable("npm", provider: id)
        return OperationPlan(
            kind: .cleanup(.providerCache),
            providerID: id,
            targets: [],
            commands: [Self.command(npm, ["cache", "clean", "--force"])],
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

    public func cleanupCandidates(context: ProviderContext) async throws -> [CleanupCandidate] {
        let npm = try context.requireExecutable("npm", provider: id)
        let cacheCommand = Self.command(npm, ["config", "get", "cache"], timeout: ScanTimeout.fast)
        let cacheResult = try await invoker.runChecked(cacheCommand, context: context)
        guard let cacheDirectory = OutputText.firstLine(cacheResult.stdoutString), cacheDirectory.hasPrefix("/") else {
            throw ProviderError.parsingFailed(id, what: "npm config get cache")
        }

        let contentCache = cacheDirectory + "/_cacache"
        guard fileSystem.isDirectory(atPath: contentCache) else { return [] }

        let usage = try? await invoker.run(DiskUsage.command(path: contentCache), context: context)
        let bytes = usage.flatMap { $0.succeeded ? DiskUsage.parseBytes($0.stdoutString) : nil }
        return [CleanupCandidate(
            kind: .providerCache,
            providerID: id,
            risk: .low,
            paths: [contentCache],
            reclaimableBytes: bytes,
            plan: try cleanupPlan(context: context)
        )]
    }
}
