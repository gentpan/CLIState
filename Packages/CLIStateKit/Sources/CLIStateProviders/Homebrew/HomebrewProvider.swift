import CLIStateDomain
import Foundation

/// Homebrew formulae, CLI casks and services. Reads through `CommandRunning`
/// and `FileSystem`; write capabilities only build `OperationPlan`s.
public struct HomebrewProvider: ToolUpdateProvider, ToolUninstallProvider, ServiceProvider,
    MetadataRefreshProvider, OperationPreflightProvider, CleanupProvider, ToolInstallProvider
{
    public let id: ProviderID = .homebrew

    /// F1: reads must never trigger `brew update`, and the plan a user confirms
    /// must be the one that runs.
    public static let environment: [String: String] = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
    ]

    /// Mutations also disable Homebrew's implicit `autoremove` (run after
    /// `uninstall`, `cleanup` and periodic cleanups), which would uninstall
    /// packages outside the confirmed plan. Orphans are their own medium-risk plan.
    public static let mutationEnvironment: [String: String] = environment.merging(["HOMEBREW_NO_AUTOREMOVE": "1"]) { _, new in new }

    private let fileSystem: any FileSystem
    private let invoker: CommandInvoker

    public init(runner: any CommandRunning, fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
        self.invoker = CommandInvoker(providerID: .homebrew, runner: runner)
    }

    // MARK: Commands

    static func command(_ executable: String, _ arguments: [String], environment: [String: String] = HomebrewProvider.environment, timeout: Duration? = nil) -> Command {
        Command(executable: executable, arguments: arguments, environmentOverrides: environment, timeout: timeout)
    }

    // MARK: ToolProvider

    public func availability(context: ProviderContext) async -> ProviderAvailability {
        guard let brew = context.resolveExecutable("brew") else {
            return .unavailable(id, reason: "executableNotFound")
        }
        do {
            let result = try await invoker.runChecked(Self.command(brew, ["--version"], timeout: ScanTimeout.fast), context: context)
            return ProviderAvailability(providerID: id, isAvailable: true, executable: brew, version: HomebrewOutputParser.version(from: result.stdoutString))
        } catch {
            return ProviderAvailability(providerID: id, isAvailable: false, executable: brew, reason: "versionCommandFailed")
        }
    }

    public func scan(context: ProviderContext, depth: ScanDepth) async throws -> ProviderInventory {
        let brew = try context.requireExecutable("brew", provider: id)
        let fast = ScanTimeout.fast

        async let versionResult = invoker.run(Self.command(brew, ["--version"], timeout: fast), context: context)
        async let prefixResult = invoker.run(Self.command(brew, ["--prefix"], timeout: fast), context: context)
        async let infoResult = invoker.run(Self.command(brew, ["info", "--json=v2", "--installed"], timeout: fast), context: context)
        async let servicesResult = invoker.run(Self.command(brew, ["services", "list", "--json"], timeout: fast), context: context)
        async let outdatedResult: CommandResult? = depth == .deep
            ? invoker.run(Self.command(brew, ["outdated", "--json=v2"], timeout: ScanTimeout.deep), context: context)
            : nil

        let (version, prefix, info, services, outdated) = try await (versionResult, prefixResult, infoResult, servicesResult, outdatedResult)
        var warnings: [String] = []
        for result in [version, prefix, info, services] + [outdated].compactMap({ $0 }) {
            warnings += OutputText.warnings(fromStderr: result.stderrString)
        }

        let prefixPath: String
        if prefix.succeeded, let path = HomebrewOutputParser.firstPath(from: prefix.stdoutString) {
            prefixPath = path
        } else {
            // `<prefix>/bin/brew` is how every supported install lays out the launcher.
            prefixPath = ((brew as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            warnings.append("brew --prefix failed; using \(prefixPath)")
        }
        let layout = HomebrewMapper.layout(prefix: prefixPath)

        let infoCommand = Self.command(brew, ["info", "--json=v2", "--installed"])
        guard info.succeeded else { throw invoker.failure(infoCommand, info) }
        let infoDTO = try JSONParsing.decode(BrewInfoDTO.self, from: info.stdout, providerID: id, what: "brew info --json=v2 --installed")

        let mapper = HomebrewMapper(layout: layout, fileSystem: fileSystem)
        var tools = infoDTO.formulae.map(mapper.tool(from:)) + infoDTO.casks.compactMap(mapper.tool(from:))

        if let outdated {
            if outdated.succeeded, let dto = try? JSONDecoder().decode(BrewOutdatedDTO.self, from: outdated.stdout) {
                tools = HomebrewMapper.merge(outdated: dto, into: tools)
            } else {
                warnings.append("brew outdated --json=v2 failed (exit \(outdated.exitCode))")
            }
        }

        var providerServices: [ProviderService] = []
        if services.succeeded, let dtos = try? JSONDecoder().decode(LossyArray<BrewServiceDTO>.self, from: services.stdout) {
            providerServices = dtos.elements.map(HomebrewMapper.service(from:))
        } else {
            warnings.append("brew services list --json failed (exit \(services.exitCode))")
        }

        let availability = ProviderAvailability(
            providerID: id,
            isAvailable: true,
            executable: brew,
            version: version.succeeded ? HomebrewOutputParser.version(from: version.stdoutString) : nil
        )
        return ProviderInventory(
            providerID: id,
            availability: availability,
            layout: layout,
            tools: tools,
            services: providerServices,
            depth: depth,
            scannedAt: context.now,
            warnings: warnings.uniquedPreservingOrder(),
            metadataUpdatedAt: HomebrewMetadata.lastUpdated(prefix: prefixPath, cacheDirectory: context.execution.variables["HOMEBREW_CACHE"], fileSystem: fileSystem)
        )
    }

    // MARK: Plans

    public func updatePlan(for tools: [ProviderTool], context: ProviderContext) throws -> OperationPlan {
        let brew = try context.requireExecutable("brew", provider: id)
        let tools = try validatedTools(tools)
        let formulae = tools.filter { $0.kind == .formula }.map(\.packageName).uniquedPreservingOrder()
        let casks = tools.filter { $0.kind == .cask }.map(\.packageName).uniquedPreservingOrder()

        var commands: [Command] = []
        if !formulae.isEmpty { commands.append(Self.command(brew, ["upgrade"] + formulae, environment: Self.mutationEnvironment)) }
        if !casks.isEmpty { commands.append(Self.command(brew, ["upgrade", "--cask"] + casks, environment: Self.mutationEnvironment)) }

        return OperationPlan(kind: .update, providerID: id, targets: tools.map(\.operationTarget), commands: commands, requiresNetwork: true)
    }

    public func uninstallPlan(for tool: ProviderTool, context: ProviderContext) throws -> OperationPlan {
        let brew = try context.requireExecutable("brew", provider: id)
        let tool = try validatedTools([tool])[0]
        let arguments = tool.kind == .cask ? ["uninstall", "--cask", tool.packageName] : ["uninstall", tool.packageName]
        return OperationPlan(
            kind: .uninstall,
            providerID: id,
            targets: [tool.operationTarget],
            commands: [Self.command(brew, arguments, environment: Self.mutationEnvironment)],
            requiresNetwork: false
        )
    }

    public func servicePlan(_ action: ServiceAction, service: ProviderService, context: ProviderContext) throws -> OperationPlan {
        guard service.providerID == id else { throw ProviderError.unsupportedOperation }
        try PackageNameValidator.validate(service.name)
        let brew = try context.requireExecutable("brew", provider: id)
        return OperationPlan(
            kind: .service(action),
            providerID: id,
            targets: [OperationTarget(packageName: service.name, displayName: service.name)],
            commands: [Self.command(brew, ["services", action.rawValue, service.name])],
            requiresNetwork: false
        )
    }

    public func refreshMetadataPlan(context: ProviderContext) throws -> OperationPlan {
        let brew = try context.requireExecutable("brew", provider: id)
        // The one Homebrew command allowed to update: it *is* the update (F1).
        var environment = Self.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = nil
        return OperationPlan(
            kind: .refreshMetadata,
            providerID: id,
            targets: [],
            commands: [Self.command(brew, ["update"], environment: environment)],
            requiresNetwork: true
        )
    }

    /// `.oldVersions` → `brew cleanup` (old kegs and caches);
    /// `.orphanedDependencies` → `brew autoremove`.
    public func cleanupPlan(_ kind: CleanupKind, context: ProviderContext) throws -> OperationPlan {
        let brew = try context.requireExecutable("brew", provider: id)
        let command: Command
        switch kind {
        case .oldVersions, .providerCache:
            command = Self.command(brew, ["cleanup"], environment: Self.mutationEnvironment)
        case .orphanedDependencies:
            command = Self.command(brew, ["autoremove"])
        case .brokenSymlink, .unusedRuntime, .leftovers:
            throw ProviderError.unsupportedOperation
        }
        let planKind: CleanupKind = kind == .providerCache ? .oldVersions : kind
        return OperationPlan(kind: .cleanup(planKind), providerID: id, targets: [], commands: [command], requiresNetwork: false)
    }

    private func validatedTools(_ tools: [ProviderTool]) throws -> [ProviderTool] {
        guard !tools.isEmpty else { throw ProviderError.unsupportedOperation }
        for tool in tools {
            guard tool.providerID == id, tool.kind == .formula || tool.kind == .cask else { throw ProviderError.unsupportedOperation }
            try PackageNameValidator.validate(tool.packageName)
        }
        return tools.uniquedByInstallation()
    }

    // MARK: Preflight

    public func preflight(for plan: OperationPlan, context: ProviderContext) async -> [PreflightCheck] {
        guard plan.providerID == id else { return [] }
        guard let brew = context.resolveExecutable("brew") else {
            return [PreflightCheck(kind: .providerAvailable, outcome: .failed, detail: "brew")]
        }
        switch plan.kind {
        case .update:
            return await upgradePreflight(plan: plan, brew: brew, context: context)
        case .uninstall:
            return await uninstallPreflight(plan: plan, brew: brew, context: context)
        case .install:
            return installPreflight(plan: plan)
        default:
            return []
        }
    }

    /// Splits `brew <verb> [--cask] names…` back into flag and names, rejecting
    /// anything this provider would not have built.
    private func packageArguments(of command: Command, verb: String) -> (cask: Bool, names: [String])? {
        guard command.arguments.first == verb else { return nil }
        var rest = Array(command.arguments.dropFirst())
        let cask = rest.first == "--cask"
        if cask { rest.removeFirst() }
        return (cask, rest)
    }

    private func invalidNames(in plan: OperationPlan, verb: String) -> [String] {
        let names = plan.targets.map(\.packageName) + plan.commands.compactMap { packageArguments(of: $0, verb: verb) }.flatMap(\.names)
        return names.filter { !PackageNameValidator.isValid($0) }
    }

    private func upgradePreflight(plan: OperationPlan, brew: String, context: ProviderContext) async -> [PreflightCheck] {
        let invalid = invalidNames(in: plan, verb: "upgrade")
        guard invalid.isEmpty else {
            return [PreflightCheck(kind: .packageNameValid, outcome: .failed, detail: invalid.joined(separator: "\n"))]
        }

        var items: [PreflightItem] = []
        var requested: [PreflightItem] = []
        var failures: [String] = []
        for step in plan.commands {
            guard let parsedStep = packageArguments(of: step, verb: "upgrade"), !parsedStep.names.isEmpty else { continue }
            let arguments = ["upgrade", "--dry-run"] + (parsedStep.cask ? ["--cask"] : []) + parsedStep.names
            let dryRun = Self.command(brew, arguments, environment: Self.mutationEnvironment, timeout: ScanTimeout.deep)
            do {
                let result = try await invoker.run(dryRun, context: context)
                guard result.succeeded else {
                    failures.append(result.termination == .timedOut ? "\(dryRun.displayString): timed out" : OutputText.errorSummary(result.stderrString))
                    continue
                }
                let parsed = HomebrewOutputParser.upgradeDryRun(result.stdoutString)
                items += parsed.items
                requested += parsed.requested
            } catch {
                failures.append(dryRun.displayString)
            }
        }

        if !failures.isEmpty {
            return [PreflightCheck(kind: .dryRun, outcome: .failed, detail: failures.joined(separator: "\n"), items: items)]
        }
        let detail = requested.map { item in
            [item.name, item.fromVersion, item.toVersion.map { "-> \($0)" }].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: "\n")
        return [PreflightCheck(kind: .dryRun, outcome: items.isEmpty ? .passed : .warning, detail: detail.isEmpty ? nil : detail, items: items)]
    }

    private func uninstallPreflight(plan: OperationPlan, brew: String, context: ProviderContext) async -> [PreflightCheck] {
        let invalid = invalidNames(in: plan, verb: "uninstall")
        guard invalid.isEmpty else {
            return [PreflightCheck(kind: .packageNameValid, outcome: .failed, detail: invalid.joined(separator: "\n"))]
        }

        var dependents: [PreflightItem] = []
        var failures: [String] = []
        for step in plan.commands {
            // Casks cannot be dependencies of formulae; `brew uses` covers formulae.
            guard let parsedStep = packageArguments(of: step, verb: "uninstall"), !parsedStep.cask else { continue }
            for name in parsedStep.names {
                let uses = Self.command(brew, ["uses", "--installed", name], timeout: ScanTimeout.deep)
                guard let result = try? await invoker.run(uses, context: context), result.succeeded else {
                    failures.append(uses.displayString)
                    continue
                }
                dependents += HomebrewOutputParser.names(fromList: result.stdoutString)
                    .map { PreflightItem(name: $0, change: .dependent) }
            }
        }

        if !failures.isEmpty {
            return [PreflightCheck(kind: .reverseDependencies, outcome: .warning, detail: failures.joined(separator: "\n"), items: dependents)]
        }
        // Homebrew refuses `brew uninstall` while installed formulae still depend
        // on the target. Surface that before the user confirms the operation.
        return [PreflightCheck(kind: .reverseDependencies, outcome: dependents.isEmpty ? .passed : .failed, items: dependents)]
    }

    // MARK: Cleanup

    public func cleanupCandidates(context: ProviderContext) async throws -> [CleanupCandidate] {
        let brew = try context.requireExecutable("brew", provider: id)
        let deep = ScanTimeout.deep
        let cleanupCommand = Self.command(brew, ["cleanup", "--dry-run"], environment: Self.mutationEnvironment, timeout: deep)
        let autoremoveCommand = Self.command(brew, ["autoremove", "--dry-run"], timeout: deep)

        async let prefixResult = invoker.run(Self.command(brew, ["--prefix"], timeout: ScanTimeout.fast), context: context)
        async let cleanupResult = invoker.run(cleanupCommand, context: context)
        async let autoremoveResult = invoker.run(autoremoveCommand, context: context)
        let (prefix, cleanup, autoremove) = try await (prefixResult, cleanupResult, autoremoveResult)

        let prefixPath = HomebrewOutputParser.firstPath(from: prefix.stdoutString)
            ?? ((brew as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let layout = HomebrewMapper.layout(prefix: prefixPath)

        guard cleanup.succeeded || autoremove.succeeded else {
            throw invoker.failure(cleanupCommand, cleanup)
        }

        var candidates: [CleanupCandidate] = []
        if cleanup.succeeded {
            let parsed = HomebrewOutputParser.cleanupDryRun(cleanup.stdoutString, layout: layout)
            if !parsed.isEmpty {
                candidates.append(CleanupCandidate(
                    kind: .oldVersions,
                    providerID: id,
                    risk: .low,
                    items: parsed.items,
                    paths: parsed.paths,
                    reclaimableBytes: parsed.reclaimableBytes,
                    plan: try cleanupPlan(.oldVersions, context: context)
                ))
            }
        }
        if autoremove.succeeded {
            let names = HomebrewOutputParser.autoremoveDryRun(autoremove.stdoutString)
            if !names.isEmpty {
                var plan = try cleanupPlan(.orphanedDependencies, context: context)
                plan.targets = names.map { OperationTarget(installationID: .package(provider: id, name: $0), packageName: $0, displayName: $0) }
                candidates.append(CleanupCandidate(
                    kind: .orphanedDependencies,
                    providerID: id,
                    risk: .medium,
                    items: names.map { PreflightItem(name: $0, change: .remove) },
                    plan: plan
                ))
            }
        }
        return candidates
    }
}
