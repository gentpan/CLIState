import CLIStateDomain
import Foundation

// Install plans for environment restore (Lane N). Every plan installs the latest
// version with the provider's own command, as argument arrays, without sudo.

enum InstallValidation {
    /// Non-empty, one kind per provider, valid names; duplicates collapse.
    static func validated(_ requests: [InstallRequest], kinds: Set<PackageKind>, allowsTap: Bool = false) throws -> [InstallRequest] {
        guard !requests.isEmpty else { throw ProviderError.unsupportedOperation }
        var seen = Set<String>()
        var result: [InstallRequest] = []
        for request in requests {
            guard kinds.contains(request.kind) else { throw ProviderError.unsupportedOperation }
            try PackageNameValidator.validate(request.packageName)
            if let tap = request.tap {
                guard allowsTap else { throw ProviderError.unsupportedOperation }
                guard isValidTap(tap) else { throw ProviderError.invalidPackageName(tap) }
                // The short name must not smuggle in its own tap.
                guard !request.packageName.contains("/") else { throw ProviderError.invalidPackageName(request.packageName) }
            }
            if seen.insert("\(request.kind.rawValue):\(request.qualifiedName)").inserted { result.append(request) }
        }
        return result
    }

    /// `user/repo`, exactly two valid segments.
    static func isValidTap(_ tap: String) -> Bool {
        PackageNameValidator.isValid(tap) && tap.split(separator: "/", omittingEmptySubsequences: false).count == 2
    }

    static func targets(_ requests: [InstallRequest]) -> [OperationTarget] {
        requests.map { OperationTarget(toolID: $0.toolID, packageName: $0.qualifiedName, displayName: $0.displayName) }
    }
}

// MARK: - Homebrew

extension HomebrewProvider {
    /// `HOMEBREW_NO_INSTALL_UPGRADE`: `brew install` of something already installed
    /// must not quietly upgrade it (and its dependents) outside the confirmed plan.
    public static let installEnvironment: [String: String] = mutationEnvironment.merging(["HOMEBREW_NO_INSTALL_UPGRADE": "1"]) { _, new in new }

    /// `brew tap <tap>` for each listed tap, then `brew install <formulae…>` and
    /// `brew install --cask <casks…>`.
    public func installPlan(for packages: [InstallRequest], context: ProviderContext) throws -> OperationPlan {
        let brew = try context.requireExecutable("brew", provider: id)
        let requests = try InstallValidation.validated(packages, kinds: [.formula, .cask], allowsTap: true)
        let taps = requests.compactMap(\.tap).uniquedPreservingOrder()
        let formulae = requests.filter { $0.kind == .formula }.map(\.qualifiedName)
        let casks = requests.filter { $0.kind == .cask }.map(\.qualifiedName)

        var commands = taps.map { Self.command(brew, ["tap", $0], environment: Self.installEnvironment) }
        if !formulae.isEmpty { commands.append(Self.command(brew, ["install"] + formulae, environment: Self.installEnvironment)) }
        if !casks.isEmpty { commands.append(Self.command(brew, ["install", "--cask"] + casks, environment: Self.installEnvironment)) }
        return OperationPlan(kind: .install, providerID: id, targets: InstallValidation.targets(requests), commands: commands, requiresNetwork: true)
    }

    /// Re-checks every name the plan would pass to brew (plans can be rebuilt from stored data).
    func installPreflight(plan: OperationPlan) -> [PreflightCheck] {
        var invalid = plan.targets.map(\.packageName).filter { !PackageNameValidator.isValid($0) }
        for command in plan.commands {
            var arguments = command.arguments
            guard let verb = arguments.first else { continue }
            arguments.removeFirst()
            switch verb {
            case "tap":
                invalid += arguments.filter { !InstallValidation.isValidTap($0) }
            case "install":
                if arguments.first == "--cask" { arguments.removeFirst() }
                invalid += arguments.filter { !PackageNameValidator.isValid($0) }
            default:
                invalid.append(verb)
            }
        }
        return [PreflightCheck(kind: .packageNameValid, outcome: invalid.isEmpty ? .passed : .failed, detail: invalid.isEmpty ? nil : invalid.joined(separator: "\n"))]
    }
}

// MARK: - npm

extension NPMProvider: ToolInstallProvider {
    /// `npm install -g <packages…>` into the npm the shell resolves.
    public func installPlan(for packages: [InstallRequest], context: ProviderContext) throws -> OperationPlan {
        let npm = try context.requireExecutable("npm", provider: id)
        let requests = try InstallValidation.validated(packages, kinds: [.globalPackage])
        return OperationPlan(
            kind: .install,
            providerID: id,
            targets: InstallValidation.targets(requests),
            commands: [Self.command(npm, ["install", "-g"] + requests.map(\.packageName))],
            requiresNetwork: true
        )
    }
}

// MARK: - pnpm

extension PNPMProvider: ToolInstallProvider {
    /// `pnpm add -g <packages…>`. Needs PNPM_HOME, checked by the same preflight as updates.
    public func installPlan(for packages: [InstallRequest], context: ProviderContext) throws -> OperationPlan {
        let pnpm = try context.requireExecutable("pnpm", provider: id)
        let requests = try InstallValidation.validated(packages, kinds: [.globalPackage])
        return OperationPlan(
            kind: .install,
            providerID: id,
            targets: InstallValidation.targets(requests),
            commands: [Self.command(pnpm, ["add", "-g"] + requests.map(\.packageName))],
            requiresNetwork: true
        )
    }
}

// MARK: - uv

extension UVProvider: ToolInstallProvider {
    /// One `uv tool install <package>` per tool: uv takes a single package per call.
    public func installPlan(for packages: [InstallRequest], context: ProviderContext) throws -> OperationPlan {
        let uv = try context.requireExecutable("uv", provider: id)
        let requests = try InstallValidation.validated(packages, kinds: [.tool])
        return OperationPlan(
            kind: .install,
            providerID: id,
            targets: InstallValidation.targets(requests),
            commands: requests.map { Self.command(uv, ["tool", "install", $0.packageName]) },
            requiresNetwork: true
        )
    }
}

// MARK: - pipx

extension PipxProvider: ToolInstallProvider {
    /// One `pipx install <package>` per venv, so a failure names the package.
    public func installPlan(for packages: [InstallRequest], context: ProviderContext) throws -> OperationPlan {
        let pipx = try context.requireExecutable("pipx", provider: id)
        let requests = try InstallValidation.validated(packages, kinds: [.tool])
        return OperationPlan(
            kind: .install,
            providerID: id,
            targets: InstallValidation.targets(requests),
            commands: requests.map { Self.command(pipx, ["install", $0.packageName]) },
            requiresNetwork: true
        )
    }
}

// MARK: - Cargo

extension CargoProvider: ToolInstallProvider {
    /// `cargo install --locked <crate>`: builds with the crate's own lockfile, as crate authors recommend.
    public func installPlan(for packages: [InstallRequest], context: ProviderContext) throws -> OperationPlan {
        let cargo = try context.requireExecutable("cargo", provider: id)
        let requests = try InstallValidation.validated(packages, kinds: [.tool])
        return OperationPlan(
            kind: .install,
            providerID: id,
            targets: InstallValidation.targets(requests),
            commands: requests.map { Self.command(cargo, ["install", "--locked", $0.packageName]) },
            requiresNetwork: true
        )
    }
}
