import CLIStateDomain
import Foundation

/// Binaries installed with `cargo install`.
public struct CargoProvider: ToolUpdateProvider, ToolUninstallProvider {
    public let id: ProviderID = .cargo

    private let fileSystem: any FileSystem
    private let invoker: CommandInvoker

    public init(runner: any CommandRunning, fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
        self.invoker = CommandInvoker(providerID: .cargo, runner: runner)
    }

    static func command(_ executable: String, _ arguments: [String], timeout: Duration? = nil) -> Command {
        Command(executable: executable, arguments: arguments, timeout: timeout)
    }

    // MARK: ToolProvider

    public func availability(context: ProviderContext) async -> ProviderAvailability {
        guard let cargo = context.resolveExecutable("cargo") else {
            return .unavailable(id, reason: "executableNotFound")
        }
        do {
            let result = try await invoker.runChecked(Self.command(cargo, ["--version"], timeout: ScanTimeout.fast), context: context)
            return ProviderAvailability(providerID: id, isAvailable: true, executable: cargo, version: CargoInstallListParser.version(from: result.stdoutString))
        } catch {
            return ProviderAvailability(providerID: id, isAvailable: false, executable: cargo, reason: "versionCommandFailed")
        }
    }

    /// Deep scans ask crates.io through cargo itself (`cargo search <name>`), since
    /// cargo has no outdated command. Git/path crates are skipped.
    public func scan(context: ProviderContext, depth: ScanDepth) async throws -> ProviderInventory {
        let cargo = try context.requireExecutable("cargo", provider: id)
        let fast = ScanTimeout.fast
        let listCommand = Self.command(cargo, ["install", "--list"], timeout: fast)

        async let versionResult = invoker.run(Self.command(cargo, ["--version"], timeout: fast), context: context)
        async let listResult = invoker.run(listCommand, context: context)

        let (version, list) = try await (versionResult, listResult)
        var warnings: [String] = []
        for result in [version, list] {
            warnings += OutputText.warnings(fromStderr: result.stderrString)
        }
        guard list.succeeded else { throw invoker.failure(listCommand, list) }

        let home = cargoHome(context: context)
        let bin = cargoInstallRoot(context: context) + "/bin"
        var tools = CargoInstallListParser.parse(list.stdoutString).map { entry in
            ProviderTool(
                providerID: id,
                packageName: entry.name,
                kind: .tool,
                installedVersions: [entry.version],
                activeVersion: entry.version,
                // Path and git installs are pinned to their source; `cargo install
                // <name>` would replace them with the crates.io release.
                isPinned: entry.source != nil,
                installPrefix: bin,
                executableNames: entry.binaries,
                executablePaths: entry.binaries.map { "\(bin)/\($0)" },
                isDirect: true
            )
        }

        if depth == .deep {
            let latest = await latestVersions(for: tools.filter { !$0.isPinned }.map(\.packageName), cargo: cargo, context: context)
            for index in tools.indices {
                guard let found = latest[tools[index].packageName] else { continue }
                tools[index].latestVersion = found.version
                if let installed = tools[index].activeVersion {
                    tools[index].isOutdated = SemanticVersion(parsing: installed).flatMap { current in
                        SemanticVersion(parsing: found.version).map { current < $0 }
                    }
                }
                if found.isDeprecated {
                    warnings.append("\(tools[index].packageName) is marked deprecated on crates.io: \(found.description)")
                }
            }
        }

        let cargoVersion = version.succeeded ? CargoInstallListParser.version(from: version.stdoutString) : nil
        return ProviderInventory(
            providerID: id,
            availability: ProviderAvailability(providerID: id, isAvailable: true, executable: cargo, version: cargoVersion),
            layout: ProviderLayout(roots: [.cargoHome: home, .cargoBin: bin]),
            tools: tools,
            depth: depth,
            scannedAt: context.now,
            warnings: warnings.uniquedPreservingOrder()
        )
    }

    /// `cargo search <name> --limit 1` per crate, a few at a time. A failed lookup
    /// (offline, renamed crate) just leaves that crate without a latest version.
    func latestVersions(for names: [String], cargo: String, context: ProviderContext) async -> [String: CargoSearchResult] {
        var results: [String: CargoSearchResult] = [:]
        var remaining = names.filter(PackageNameValidator.isValid)[...]
        while !remaining.isEmpty {
            let batch = remaining.prefix(4)
            remaining = remaining.dropFirst(batch.count)
            await withTaskGroup(of: (String, CargoSearchResult?).self) { group in
                for name in batch {
                    group.addTask {
                        let command = Self.command(cargo, ["search", name, "--limit", "1", "--color", "never"], timeout: .seconds(20))
                        guard let result = try? await invoker.run(command, context: context), result.succeeded else { return (name, nil) }
                        return (name, CargoSearchResult.parse(result.stdoutString, name: name))
                    }
                }
                for await (name, found) in group {
                    if let found { results[name] = found }
                }
            }
        }
        return results
    }

    /// `$CARGO_HOME` from the user's shell, else cargo's default `~/.cargo`.
    func cargoHome(context: ProviderContext) -> String {
        context.persistedDirectory("CARGO_HOME") ?? fileSystem.homeDirectory + "/.cargo"
    }

    /// Where `cargo install` puts binaries: `$CARGO_INSTALL_ROOT` when set, else `$CARGO_HOME`.
    func cargoInstallRoot(context: ProviderContext) -> String {
        context.persistedDirectory("CARGO_INSTALL_ROOT") ?? cargoHome(context: context)
    }

    // MARK: Plans

    /// One `cargo install <name>` per crate. Cargo only rebuilds when crates.io
    /// has a newer version; crates installed from a path or git are refused.
    public func updatePlan(for tools: [ProviderTool], context: ProviderContext) throws -> OperationPlan {
        let cargo = try context.requireExecutable("cargo", provider: id)
        let tools = try validatedTools(tools)
        guard tools.allSatisfy({ !$0.isPinned }) else { throw ProviderError.unsupportedOperation }
        return OperationPlan(
            kind: .update,
            providerID: id,
            targets: tools.map(\.operationTarget),
            commands: tools.map(\.packageName).uniquedPreservingOrder().map { Self.command(cargo, ["install", $0]) },
            requiresNetwork: true
        )
    }

    public func uninstallPlan(for tool: ProviderTool, context: ProviderContext) throws -> OperationPlan {
        let cargo = try context.requireExecutable("cargo", provider: id)
        let tool = try validatedTools([tool])[0]
        return OperationPlan(
            kind: .uninstall,
            providerID: id,
            targets: [tool.operationTarget],
            commands: [Self.command(cargo, ["uninstall", tool.packageName])],
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

struct CargoSearchResult: Hashable, Sendable {
    var version: String
    var description: String

    var isDeprecated: Bool { description.localizedCaseInsensitiveContains("deprecated") }

    /// First line `name = "1.2.3"    # description`, only for an exact name match
    /// (search results are fuzzy).
    static func parse(_ output: String, name: String) -> CargoSearchResult? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == name else { continue }
            let rest = parts[1]
            guard let open = rest.firstIndex(of: "\""), let close = rest[rest.index(after: open)...].firstIndex(of: "\"") else { continue }
            let version = String(rest[rest.index(after: open)..<close])
            let description = rest[rest.index(after: close)...].split(separator: "#", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return CargoSearchResult(version: version, description: description)
        }
        return nil
    }
}
