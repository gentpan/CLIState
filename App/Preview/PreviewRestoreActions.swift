import CLIStateApplication
import CLIStateDomain
import Foundation

/// Environment restore against `SampleSnapshot`: real diff and staging logic,
/// simulated plans, output and rescans. Runs no processes.
extension PreviewActions: RestoreActions {
    func exportProfile(name: String?, note: String?) async -> EnvironmentProfile? {
        if pace > 0 { try? await Task.sleep(for: .milliseconds(300 * pace)) }
        return EnvironmentRestore.exportProfile(snapshot: snapshot, source: ProfileSource(architecture: "arm64", macOSVersion: "15.6", appVersion: "0.1.1"), name: name, note: note)
    }

    func planInstall(_ groups: [RestoreProviderGroup], snapshot: EnvironmentSnapshot?) async throws -> PreparedOperation {
        if pace > 0 { try? await Task.sleep(for: .milliseconds(250 * pace)) }
        var plans: [PreparedPlan] = []
        for group in groups {
            guard let executable = SampleRestore.executable(for: group.provider),
                  self.snapshot.providers.contains(where: { $0.providerID == group.provider && $0.availability.isAvailable })
            else { throw ProviderError.unavailable(group.provider) }
            let requests = RestoreText.installRequests(group, snapshot: snapshot)
            let plan = OperationPlan(
                kind: .install,
                providerID: group.provider,
                targets: requests.map { OperationTarget(toolID: $0.toolID, packageName: $0.qualifiedName, displayName: $0.displayName) },
                commands: SampleRestore.commands(for: group.provider, requests: requests, executable: executable),
                requiresNetwork: true
            )
            plans.append(PreparedPlan(plan: plan, checks: [
                PreflightCheck(kind: .providerAvailable, outcome: .passed, detail: executable),
                PreflightCheck(kind: .packageNameValid, outcome: .passed),
                PreflightCheck(kind: .networkRequired, outcome: .info),
            ]))
        }
        return PreparedOperation(plans: plans)
    }

    func installLines(_ plan: OperationPlan) -> [(String, Bool)] {
        let names = plan.targets.map(\.packageName)
        switch plan.providerID {
        case .homebrew:
            var lines = plan.commands.filter { $0.arguments.first == "tap" }.map { ("==> Tapping \($0.arguments.dropFirst().joined())", false) }
            lines.append(("==> Fetching downloads for: \(names.joined(separator: ", "))", false))
            for name in names {
                let short = (name as NSString).lastPathComponent
                let version = SampleRestore.version(for: short)
                lines.append(("==> Pouring \(short)--\(version).arm64_tahoe.bottle.tar.gz", false))
                lines.append(("/opt/homebrew/Cellar/\(short)/\(version): 214 files, 18.4MB", false))
            }
            return lines
        case .npm, .pnpm:
            return [("added \(names.count * 7) packages in 6s", false)]
        default:
            return names.flatMap { [("Resolved 24 packages in 410ms", false), ("Installed 1 executable: \($0)", false)] }
        }
    }

    /// Mirrors what the verifying rescan would find, including package managers
    /// that become available (Node.js from Homebrew brings npm).
    func applyInstall(_ plan: OperationPlan, at date: Date) {
        for target in plan.targets {
            let name = plan.providerID == .homebrew ? (target.packageName as NSString).lastPathComponent : target.packageName
            let version = SampleRestore.version(for: name)
            let installation: ToolInstallation = switch plan.providerID {
            case .homebrew:
                SampleSnapshot.brewInstallation(name, version: version, latest: version, commands: [name], linkState: .active, at: date)
            case .npm:
                SampleSnapshot.npmInstallation(name, version: version, latest: version, commands: [name], entry: "bin/\(name).js", at: date)
            default:
                ToolInstallation(
                    id: .package(provider: plan.providerID, name: name),
                    ownership: Ownership(provider: plan.providerID, packageName: name, confidence: .confirmed, evidence: [.inventoryContains(provider: plan.providerID, package: name)]),
                    version: SampleSnapshot.observed(version, .provider(plan.providerID), .confirmed, date),
                    executables: [ExecutableRef(name: name, path: "\(SampleSnapshot.home)/.local/bin/\(name)", pathPriority: 10, architecture: .arm64)],
                    linkState: .active,
                    isDirect: true,
                    capabilities: ToolCapabilities(canUpdate: true, canUninstall: true)
                )
            }
            let toolID = target.toolID ?? ToolID("\(plan.providerID.rawValue).\(name)")
            if let index = snapshot.tools.firstIndex(where: { $0.id == toolID }) {
                snapshot.tools[index].installations.append(installation)
            } else {
                let candidate = EnvironmentRestore.candidates.first { $0.toolID == toolID }
                snapshot.tools.append(SampleSnapshot.tool(
                    toolID.rawValue, name: name, display: target.displayName, summary: candidate?.summary,
                    category: candidate?.category ?? .developerTool, installations: [installation],
                    command: installation.executables.first?.name, health: .healthy, at: date
                ))
            }
            if let provider = SampleRestore.providedBy[toolID], !snapshot.providers.contains(where: { $0.providerID == provider }),
               let executable = SampleRestore.executable(for: provider) {
                snapshot.providers.append(ProviderSnapshot(
                    providerID: provider,
                    availability: ProviderAvailability(providerID: provider, isAvailable: true, executable: executable, version: version),
                    freshness: .fresh(date)
                ))
            }
        }
    }
}

/// A profile "from the old Mac" that diffs realistically against `SampleSnapshot`.
enum SampleRestore {
    static let fileName = "MacBook-Pro-2024.clistate-profile.json"

    static func profile() -> EnvironmentProfile {
        EnvironmentProfile(
            createdAt: Date(timeIntervalSince1970: 1_788_000_000),
            name: "MacBook Pro 2024",
            note: "Work laptop before the upgrade",
            source: ProfileSource(architecture: "arm64", macOSVersion: "15.6", appVersion: "0.1.1"),
            items: [
                ProfileItem(toolID: "git", provider: .homebrewFormula, packageName: "git", version: "2.51.0"),
                ProfileItem(toolID: "gh", provider: .homebrewFormula, packageName: "gh", version: "2.100.0"),
                ProfileItem(toolID: "node", provider: .homebrewFormula, packageName: "node", version: "26.8.2"),
                ProfileItem(toolID: "php", provider: .homebrewFormula, packageName: "php", version: "8.5.7", pinned: true),
                ProfileItem(toolID: "composer", provider: .homebrewFormula, packageName: "composer", version: "2.9.8"),
                ProfileItem(toolID: "go", provider: .homebrewFormula, packageName: "go", version: "1.27.1"),
                ProfileItem(toolID: "postgresql", provider: .homebrewFormula, packageName: "postgresql@17", version: "17.10"),
                ProfileItem(toolID: "redis", provider: .homebrewFormula, packageName: "redis", version: "8.2.1"),
                ProfileItem(toolID: "jq", provider: .homebrewFormula, packageName: "jq", version: "1.8.1"),
                ProfileItem(toolID: "terraform", provider: .homebrewFormula, packageName: "terraform", version: "1.13.3", tap: "hashicorp/tap"),
                // pipx comes from Homebrew, so poetry waits for the second stage.
                ProfileItem(toolID: "pipx", provider: .homebrewFormula, packageName: "pipx", version: "1.8.0"),
                ProfileItem(provider: .homebrewCask, packageName: "ghostty", version: "1.2.0"),
                ProfileItem(toolID: "pnpm", provider: .npm, packageName: "pnpm", version: "10.33.0"),
                ProfileItem(toolID: "claude-code", provider: .npm, packageName: "@anthropic-ai/claude-code", version: "2.1.270"),
                ProfileItem(toolID: "codex", provider: .npm, packageName: "@openai/codex", version: "0.41.0"),
                ProfileItem(toolID: "gemini-cli", provider: .npm, packageName: "@google/gemini-cli", version: "0.8.2"),
                ProfileItem(toolID: "kimi-cli", provider: .uv, packageName: "kimi-cli", version: "1.49.0"),
                ProfileItem(toolID: "ruff", provider: .uv, packageName: "ruff", version: "0.13.2"),
                ProfileItem(provider: .pipx, packageName: "poetry", version: "2.2.1"),
                ProfileItem(provider: .cargo, packageName: "bat", version: "0.25.0"),
            ]
        )
    }

    static let providedBy: [ToolID: ProviderID] = ["node": .npm, "pnpm": .pnpm, "uv": .uv, "pipx": .pipx, "rust": .cargo]

    static func executable(for provider: ProviderID) -> String? {
        switch provider {
        case .homebrew: SampleSnapshot.brew
        case .npm: "/opt/homebrew/bin/npm"
        case .pnpm: "\(SampleSnapshot.home)/Library/pnpm/pnpm"
        case .uv: "\(SampleSnapshot.home)/.local/bin/uv"
        case .pipx: "/opt/homebrew/bin/pipx"
        case .cargo: "\(SampleSnapshot.home)/.cargo/bin/cargo"
        default: nil
        }
    }

    static func commands(for provider: ProviderID, requests: [InstallRequest], executable: String) -> [Command] {
        switch provider {
        case .homebrew:
            let environment = SampleSnapshot.homebrewEnv.merging(["HOMEBREW_NO_AUTOREMOVE": "1", "HOMEBREW_NO_INSTALL_UPGRADE": "1"]) { _, new in new }
            var commands = Array(Set(requests.compactMap(\.tap))).sorted().map { Command(executable: executable, arguments: ["tap", $0], environmentOverrides: environment) }
            let formulae = requests.filter { $0.kind == .formula }.map(\.qualifiedName)
            let casks = requests.filter { $0.kind == .cask }.map(\.qualifiedName)
            if !formulae.isEmpty { commands.append(Command(executable: executable, arguments: ["install"] + formulae, environmentOverrides: environment)) }
            if !casks.isEmpty { commands.append(Command(executable: executable, arguments: ["install", "--cask"] + casks, environmentOverrides: environment)) }
            return commands
        case .npm: return [Command(executable: executable, arguments: ["install", "-g"] + requests.map(\.packageName))]
        case .pnpm: return [Command(executable: executable, arguments: ["add", "-g"] + requests.map(\.packageName))]
        case .uv: return requests.map { Command(executable: executable, arguments: ["tool", "install", $0.packageName]) }
        case .pipx: return requests.map { Command(executable: executable, arguments: ["install", $0.packageName]) }
        default: return requests.map { Command(executable: executable, arguments: ["install", "--locked", $0.packageName]) }
        }
    }

    static func version(for package: String) -> String {
        [
            "git": "2.51.0", "redis": "8.2.1", "jq": "1.8.1", "terraform": "1.13.3", "ghostty": "1.2.0",
            "@openai/codex": "0.41.0", "@google/gemini-cli": "0.8.2", "ruff": "0.13.2", "pipx": "1.8.0",
            "poetry": "2.2.1", "rust": "1.90.0", "bat": "0.25.0", "deno": "2.5.2", "yarn": "1.22.22",
        ][package] ?? "1.0.0"
    }
}
