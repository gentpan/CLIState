import CLIStateDomain
import Foundation

/// DTO → `ProviderTool` / `ProviderService`. Pure apart from listing
/// `<prefix>/opt/<name>/bin` through the injected `FileSystem`.
struct HomebrewMapper {
    let layout: ProviderLayout
    let fileSystem: any FileSystem

    private var prefix: String { layout[.homebrewPrefix] ?? "" }
    private var cellar: String { layout[.homebrewCellar] ?? prefix + "/Cellar" }
    private var caskroom: String { layout[.homebrewCaskroom] ?? prefix + "/Caskroom" }

    static func layout(prefix: String) -> ProviderLayout {
        ProviderLayout(roots: [
            .homebrewPrefix: prefix,
            .homebrewCellar: prefix + "/Cellar",
            .homebrewCaskroom: prefix + "/Caskroom",
        ])
    }

    // MARK: Formulae

    func tool(from formula: BrewFormulaDTO) -> ProviderTool {
        let versions = formula.installed.compactMap(\.version)
        let selectedVersion = formula.linkedKeg ?? versions.last
        let selectedEntry = formula.installed.last { $0.version == selectedVersion } ?? formula.installed.last
        let directFlags = formula.installed.compactMap(\.installedOnRequest)

        return ProviderTool(
            providerID: .homebrew,
            packageName: formula.name,
            kind: .formula,
            displayName: formula.fullName.flatMap { $0 == formula.name ? nil : $0 },
            summary: formula.desc,
            homepage: formula.homepage,
            installedVersions: versions,
            activeVersion: formula.linkedKeg,
            latestVersion: Self.latestVersion(stable: formula.versions?.stable, revision: formula.revision),
            isOutdated: formula.outdated,
            isPinned: formula.pinned ?? false,
            installPrefix: selectedVersion.map { "\(cellar)/\(formula.name)/\($0)" },
            executableNames: executableNames(formula: formula.name, installPrefix: selectedVersion.map { "\(cellar)/\(formula.name)/\($0)" }),
            // C8: a formula is direct if any installed keg was requested by the user.
            isDirect: directFlags.isEmpty ? nil : directFlags.contains(true),
            isKegOnly: formula.kegOnly ?? false,
            dependencies: formula.dependencies,
            installedAt: selectedEntry?.time.map { Date(timeIntervalSince1970: $0) },
            tap: Self.tap(fromFullName: formula.fullName)
        )
    }

    /// `hashicorp/tap/terraform` → `hashicorp/tap`; core names have no tap.
    static func tap(fromFullName fullName: String?) -> String? {
        guard let parts = fullName?.split(separator: "/", omittingEmptySubsequences: false), parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty })
        else { return nil }
        let tap = "\(parts[0])/\(parts[1])"
        return tap == "homebrew/core" || tap == "homebrew/cask" ? nil : tap
    }

    /// Homebrew's `pkg_version`: `stable` plus `_<revision>` when the formula was rebuilt.
    static func latestVersion(stable: String?, revision: Int?) -> String? {
        guard let stable, !stable.isEmpty else { return nil }
        guard let revision, revision > 0 else { return stable }
        return "\(stable)_\(revision)"
    }

    private func executableNames(formula: String, installPrefix: String?) -> [String] {
        var roots = ["\(prefix)/opt/\(formula)"]
        if let installPrefix { roots.append(installPrefix) }
        for root in roots where fileSystem.isDirectory(atPath: root) {
            return ["bin", "sbin"].flatMap { listExecutables(in: "\(root)/\($0)") }.uniquedPreservingOrder()
        }
        return []
    }

    private func listExecutables(in directory: String) -> [String] {
        guard let entries = try? fileSystem.contentsOfDirectory(atPath: directory) else { return [] }
        return entries
            .filter { !$0.hasPrefix(".") && fileSystem.isExecutableFile(atPath: "\(directory)/\($0)") }
            .sorted()
    }

    // MARK: Casks

    /// `nil` for GUI-only and font casks: only casks exposing a `binary` count as CLI tools (F7).
    func tool(from cask: BrewCaskDTO) -> ProviderTool? {
        let binaries = cask.artifacts.filter { $0.binary != nil }
        guard !binaries.isEmpty else { return nil }

        let names = binaries.compactMap(Self.executableName).uniquedPreservingOrder()
        let paths = binaries.compactMap(\.target).filter { $0.hasPrefix("/") }.uniquedPreservingOrder()

        return ProviderTool(
            providerID: .homebrew,
            packageName: cask.token,
            kind: .cask,
            displayName: cask.names.first,
            summary: cask.desc,
            homepage: cask.homepage,
            installedVersions: cask.installed.map { [$0] } ?? [],
            activeVersion: cask.installed,
            latestVersion: cask.version,
            isOutdated: cask.outdated,
            isPinned: cask.pinned ?? false,
            installPrefix: cask.installed.map { "\(caskroom)/\(cask.token)/\($0)" },
            executableNames: names,
            executablePaths: paths,
            isDirect: true,
            installedAt: cask.installedTime.map { Date(timeIntervalSince1970: $0) },
            tap: Self.tap(fromFullName: cask.fullToken)
        )
    }

    /// The `{target:}` option wins; otherwise the source file name.
    static func executableName(of artifact: BrewCaskDTO.Artifact) -> String? {
        guard let entries = artifact.binary else { return nil }
        var source: String?
        var target: String?
        for entry in entries {
            switch entry {
            case let .source(path): source = source ?? path
            case let .options(value): target = target ?? value
            }
        }
        guard let chosen = target ?? source else { return nil }
        let name = (chosen as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    // MARK: Deep scan

    /// `brew outdated` is authoritative for casks (and for pinned formulae),
    /// which `brew info` reports less precisely (F11).
    static func merge(outdated: BrewOutdatedDTO, into tools: [ProviderTool]) -> [ProviderTool] {
        let formulae = Dictionary(outdated.formulae.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let casks = Dictionary(outdated.casks.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return tools.map { tool in
            var tool = tool
            let entries = tool.kind == .cask ? casks : formulae
            if let entry = entries[tool.packageName] {
                tool.isOutdated = true
                if let current = entry.currentVersion { tool.latestVersion = current }
                if let pinned = entry.pinned { tool.isPinned = pinned }
            }
            return tool
        }
    }

    // MARK: Services

    static func service(from dto: BrewServiceDTO) -> ProviderService {
        ProviderService(
            providerID: .homebrew,
            name: dto.name,
            status: serviceStatus(dto.status),
            rawStatus: dto.status,
            user: dto.user,
            plistPath: dto.file,
            exitCode: dto.exitCode
        )
    }

    static func serviceStatus(_ raw: String?) -> ServiceStatus {
        switch raw?.lowercased() {
        case "started": .running
        case "none", "stopped": .stopped
        case "scheduled": .scheduled
        case "error": .error
        default: .unknown
        }
    }
}
