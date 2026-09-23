import CLIStateDomain
import CryptoKit
import Foundation

public struct MergeResult: Hashable, Sendable {
    public var tools: [Tool]
    public var services: [ToolService]
    /// Installations whose inventory marks them pinned to their source (`ProviderTool.isPinned`).
    public var pinnedInstallations: Set<InstallationID>

    public init(tools: [Tool], services: [ToolService], pinnedInstallations: Set<InstallationID> = []) {
        self.tools = tools
        self.services = services
        self.pinnedInstallations = pinnedInstallations
    }
}

/// Turns attributed executables and provider inventories into canonical tools
/// (plan §6.5, §77): one `Tool` per registry definition with every installation
/// under it, provider-only packages as `<provider>.<name>` (npm, pnpm and bun share
/// `npm.<name>`), scripts run by a Homebrew keg's interpreter as `homebrew.<formula>:<name>`,
/// and unowned PATH executables as `unknown.<sha256>`.
///
/// `merge` fills structure, link states, resolution, services and dependents
/// with versions known without running anything (inventory, path). `finalize`
/// runs after version probing and computes capabilities, config paths and
/// architectures, which depend on confirmed ownership and versions.
public struct MergeEngine: Sendable {
    public let registry: ToolRegistry
    public let attribution: AttributionEngine
    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem, registry: ToolRegistry = .standard, attribution: AttributionEngine) {
        self.fileSystem = fileSystem
        self.registry = registry
        self.attribution = attribution
    }

    // MARK: - Merge

    public func merge(discovery: DiscoveryResult, inventories: [ProviderInventory], now: Date) -> MergeResult {
        let packages = PackageIndex(inventories: inventories, registry: registry)
        let brokenLinks = brokenLinks(in: discovery)
        let located = locateExecutables(discovery: discovery, brokenLinks: brokenLinks)
        var brokenPaths = Set(brokenLinks.map(\.path))

        var bound: [InstallationID: [Located]] = [:]
        var unbound: [Located] = []
        for item in located {
            if let entry = packages.entry(for: item.attribution.ownership) {
                bound[entry.installationID, default: []].append(item)
            } else if item.attribution.ownership.provider != .system, let entry = packages.entry(forExecutablePath: item.path) {
                // Provider lists this exact path, but nothing in the path proves it.
                var rebound = item
                rebound.attribution = Attribution(
                    ownership: Ownership(provider: entry.providerID, instance: entry.instanceID, packageName: entry.tool.packageName, confidence: .probable,
                                         evidence: [.inventoryContains(provider: entry.providerID, package: entry.tool.packageName)]),
                    installPrefix: entry.tool.installPrefix,
                    packageKind: entry.tool.kind
                )
                bound[entry.installationID, default: []].append(rebound)
            } else if !item.isBroken {
                unbound.append(item)
            }
            // A dangling link no inventory package claims is not an installation of
            // anything: it only surfaces as a brokenSymlink issue and cleanup candidate.
        }

        var drafts: [ToolID: ToolDraft] = [:]
        for entry in packages.entries {
            let installation = packageInstallation(entry, located: bound[entry.installationID] ?? [], packages: packages, brokenPaths: &brokenPaths)
            let identity = entry.definition?.identity ?? packageIdentity(entry)
            drafts[entry.toolID, default: ToolDraft(identity: identity)].add(installation, names: entry.tool.executableNames)
        }
        for (key, items) in groupPathOnly(unbound) {
            let installation = pathInstallation(items, definition: registry.definition(key.toolID), now: now)
            drafts[key.toolID, default: ToolDraft(identity: key.identity)].add(installation, names: items.map(\.name))
        }

        let services = mergeServices(inventories: inventories, packages: packages)
        let tools = drafts.map { id, draft in
            buildTool(id: id, draft: draft, discovery: discovery, brokenPaths: brokenPaths, services: services, now: now)
        }
        let pinned = Set(packages.entries.filter(\.tool.isPinned).map(\.installationID))
        return MergeResult(tools: tools.sorted { $0.id < $1.id }, services: services.sorted { $0.id < $1.id }, pinnedInstallations: pinned)
    }

    // MARK: - Finalize

    /// Capabilities (plan §4), existing config paths and Mach-O architectures (§193).
    public func finalize(_ tools: [Tool], services: [ToolService], pinnedInstallations: Set<InstallationID> = [], architectureCache: inout [String: CPUArchitecture]) -> [Tool] {
        let reader = MachOReader(fileSystem: fileSystem)
        let installationsWithService = Set(services.compactMap(\.installationID))
        return tools.map { tool in
            var tool = tool
            let definition = tool.identity.registryID.flatMap { registry.definition(ToolID($0)) }
            let command = tool.resolution?.command
            let readAll = definition?.category == .runtime || tool.installations.count > 1

            for index in tool.installations.indices {
                var installation = tool.installations[index]
                if let definition {
                    installation.configPaths = configPaths(definition: definition, installation: installation)
                }
                installation.capabilities = capabilities(
                    for: installation, definition: definition,
                    hasService: installationsWithService.contains(installation.id),
                    isPinned: pinnedInstallations.contains(installation.id)
                )

                if readAll || installation.id == tool.activeInstallationID,
                   let primary = Self.primaryExecutableIndex(in: installation, command: command, fileSystem: fileSystem) {
                    let executable = installation.executables[primary]
                    let target = executable.resolvedPath ?? executable.path
                    if architectureCache[target] == nil, let architecture = reader.architecture(atPath: target) {
                        architectureCache[target] = architecture
                    }
                    installation.executables[primary].architecture = architectureCache[target]
                }
                tool.installations[index] = installation
            }

            if var resolution = tool.resolution {
                for index in resolution.chain.indices {
                    let target = resolution.chain[index].resolvedPath ?? resolution.chain[index].path
                    resolution.chain[index].architecture = architectureCache[target]
                }
                tool.resolution = resolution
            }
            // Probing may have added versions and confirmed native ownership since `merge`.
            tool.installations = Self.presentationOrder(tool.installations, activeID: tool.activeInstallationID)
            return tool
        }
    }

    /// The executable to probe or inspect: the PATH copy of the resolved command when
    /// present, otherwise any executable that still exists.
    static func primaryExecutableIndex(in installation: ToolInstallation, command: String?, fileSystem: any FileSystem) -> Int? {
        let working = installation.executables.indices.filter { index in
            let executable = installation.executables[index]
            return executable.resolvedPath != nil || fileSystem.resolvingSymlinks(atPath: executable.path) != nil
        }
        if let command, let match = working.first(where: { installation.executables[$0].name == command && installation.executables[$0].pathPriority != nil }) {
            return match
        }
        if let command, let match = working.first(where: { installation.executables[$0].name == command }) {
            return match
        }
        return working.first
    }

    func capabilities(for installation: ToolInstallation, definition: ToolDefinition?, hasService: Bool, isPinned: Bool = false) -> ToolCapabilities {
        guard !installation.isSystemManaged else { return .none }
        var capabilities = ToolCapabilities()
        let ownership = installation.ownership
        if ownership.permitsMutation {
            switch ownership.provider {
            case .homebrew, .uv:
                // `brew pin`ned formulae are skipped by `brew upgrade`, so offering
                // an update would only ever end as "version unchanged".
                if ownership.packageName != nil {
                    capabilities.canUpdate = !isPinned
                    capabilities.canUninstall = true
                }
            case .pipx, .pnpm, .cargo:
                // Pinned: a git/path crate, a `link:` pnpm package or a pinned pipx venv.
                // Updating would replace it with the registry release, or silently do nothing.
                if ownership.packageName != nil {
                    capabilities.canUpdate = !isPinned
                    capabilities.canUninstall = true
                }
            case .npm:
                if ownership.packageName != nil, npmRootIsWritable(ownership) {
                    capabilities.canUpdate = true
                    capabilities.canUninstall = true
                }
            case .native:
                capabilities.canUpdate = definition?.selfUpdateArguments != nil
            default:
                break
            }
            if hasService {
                capabilities.canStart = true
                capabilities.canStop = true
                capabilities.canRestart = true
            }
        }
        let inSystemLocation = installation.executables.contains { AttributionEngine.isSystemLocation($0.path) }
        capabilities.canMoveToTrash = !inSystemLocation && (ownership.provider == .standalone || installation.linkState == .broken)
        capabilities.canOpenConfig = !installation.configPaths.isEmpty
        return capabilities
    }

    private func npmRootIsWritable(_ ownership: Ownership) -> Bool {
        guard let root = ownership.instance.flatMap(AttributionContext.root(fromInstanceID:)) else { return true }
        // Unknown on this filesystem → don't block; preflight re-checks before running (§7).
        return !fileSystem.exists(atPath: root) || fileSystem.isWritable(atPath: root)
    }

    func configPaths(definition: ToolDefinition, installation: ToolInstallation) -> [String] {
        let version = installation.version?.value.rawValue
        let brewPrefix = homebrewPrefix(of: installation)
        var result: [String] = []
        for template in definition.configPaths {
            var path = template
            if path.contains("{brew}") {
                guard let brewPrefix else { continue }
                path = path.replacingOccurrences(of: "{brew}", with: brewPrefix)
            }
            if path.contains("{mm}") {
                guard let value = version.flatMap(VersionText.majorMinor) else { continue }
                path = path.replacingOccurrences(of: "{mm}", with: value)
            }
            if path.contains("{major}") {
                guard let value = version.flatMap(VersionText.major) else { continue }
                path = path.replacingOccurrences(of: "{major}", with: value)
            }
            path = attribution.context.expand(path)
            if fileSystem.exists(atPath: path) { result.append(path) }
        }
        return result.uniqued()
    }

    private func homebrewPrefix(of installation: ToolInstallation) -> String? {
        guard installation.ownership.provider == .homebrew else { return nil }
        let candidates = [installation.installPrefix] + installation.executables.flatMap { [$0.resolvedPath, $0.path] }
        for prefix in attribution.context.homebrewPrefixes {
            if candidates.contains(where: { $0.map { PathUtil.isInside($0, prefix) } == true }) { return prefix }
        }
        return attribution.context.homebrewPrefixes.first
    }

    // MARK: - Locating executables

    struct Located: Hashable, Sendable {
        var name: String
        var path: String
        var resolvedPath: String?
        var pathPriority: Int?
        var isBroken: Bool
        var attribution: Attribution

        var effectivePath: String { resolvedPath ?? path }

        var reference: ExecutableRef {
            ExecutableRef(name: name, path: path, resolvedPath: resolvedPath, pathPriority: pathPriority)
        }
    }

    /// Broken links in discovery plus candidates whose symlink does not resolve.
    func brokenLinks(in discovery: DiscoveryResult) -> [BrokenSymlink] {
        var links = discovery.binaries.brokenSymlinks
        var seen = Set(links.map(\.path))
        for group in discovery.binaries.groups.values {
            for candidate in group.candidates where candidate.isSymlink && candidate.resolvedPath == nil && !seen.contains(candidate.path) {
                let destination = (try? fileSystem.destinationOfSymbolicLink(atPath: candidate.path)) ?? candidate.path
                links.append(BrokenSymlink(path: candidate.path, destination: destination, pathPriority: candidate.pathPriority))
                seen.insert(candidate.path)
            }
        }
        return links.sorted { ($0.pathPriority, $0.path) < ($1.pathPriority, $1.path) }
    }

    /// Working candidates for one command name, in PATH order.
    static func workingCandidates(named name: String, in discovery: DiscoveryResult) -> [BinaryCandidate] {
        discovery.binaries.candidates(named: name).filter { !($0.isSymlink && $0.resolvedPath == nil) }
    }

    private func locateExecutables(discovery: DiscoveryResult, brokenLinks: [BrokenSymlink]) -> [Located] {
        var result: [Located] = []
        var seenPaths = Set<String>()
        for group in discovery.binaries.groups.values {
            for candidate in group.candidates where !(candidate.isSymlink && candidate.resolvedPath == nil) {
                guard seenPaths.insert(candidate.path).inserted else { continue }
                result.append(Located(
                    name: candidate.name, path: candidate.path, resolvedPath: candidate.resolvedPath,
                    pathPriority: candidate.pathPriority, isBroken: false, attribution: attribution.attribute(candidate)
                ))
            }
        }
        for link in brokenLinks where seenPaths.insert(link.path).inserted {
            result.append(Located(
                name: PathUtil.lastComponent(link.path), path: link.path, resolvedPath: nil,
                pathPriority: link.pathPriority, isBroken: true, attribution: attribution.attribute(link)
            ))
        }
        let scanner = VersionManagerScanner(fileSystem: fileSystem, registry: registry, context: attribution.context)
        let resolvedOnPath = Set(result.compactMap(\.resolvedPath))
        for found in scanner.scan() where !seenPaths.contains(found.path) {
            let resolved = fileSystem.resolvingSymlinks(atPath: found.path) ?? found.path
            guard !resolvedOnPath.contains(resolved) else { continue }
            seenPaths.insert(found.path)
            result.append(Located(
                name: found.name, path: found.path, resolvedPath: resolved, pathPriority: nil, isBroken: false,
                attribution: attribution.attribute(name: found.name, path: found.path, resolvedPath: resolved)
            ))
        }
        return result.sorted { ($0.pathPriority ?? Int.max, $0.path) < ($1.pathPriority ?? Int.max, $1.path) }
    }

    // MARK: - Package installations

    private func packageInstallation(_ entry: PackageIndex.Entry, located: [Located], packages: PackageIndex, brokenPaths: inout Set<String>) -> ToolInstallation {
        let tool = entry.tool
        var executables = located.map(\.reference)
        var extra: [Located] = []
        var knownPaths = Set(executables.map(\.path))
        var knownNames = Set(executables.map(\.name))
        for path in tool.executablePaths where !knownPaths.contains(path) && (fileSystem.exists(atPath: path) || fileSystem.resolvingSymlinks(atPath: path) != nil) {
            let resolved = fileSystem.resolvingSymlinks(atPath: path)
            let name = PathUtil.lastComponent(path)
            if resolved == nil { brokenPaths.insert(path) }
            extra.append(Located(name: name, path: path, resolvedPath: resolved, pathPriority: nil, isBroken: resolved == nil,
                                 attribution: attribution.attribute(name: name, path: path, resolvedPath: resolved)))
            knownPaths.insert(path)
            knownNames.insert(name)
        }
        if let prefix = tool.installPrefix {
            for name in tool.executableNames where !knownNames.contains(name) {
                let path = "\(prefix)/bin/\(name)"
                guard !knownPaths.contains(path), fileSystem.isExecutableFile(atPath: path) else { continue }
                let resolved = fileSystem.resolvingSymlinks(atPath: path)
                extra.append(Located(name: name, path: path, resolvedPath: resolved, pathPriority: nil, isBroken: false,
                                     attribution: attribution.attribute(name: name, path: path, resolvedPath: resolved)))
                knownPaths.insert(path)
            }
        }
        executables += extra.map(\.reference)

        let inventoryEvidence = AttributionEvidence.inventoryContains(provider: entry.providerID, package: tool.packageName)
        let supporting = (located + extra).filter { $0.attribution.ownership.provider == entry.providerID }
        var ownership: Ownership
        if let best = supporting.first(where: { $0.attribution.ownership.confidence == .confirmed }) ?? supporting.first {
            ownership = best.attribution.ownership
            ownership.instance = entry.instanceID
            ownership.packageName = tool.packageName
            if !ownership.evidence.contains(inventoryEvidence) { ownership.evidence.insert(inventoryEvidence, at: 0) }
        } else {
            // Nothing on disk contradicts the provider's own inventory (e.g. a library
            // formula without executables), so the inventory alone identifies the owner.
            var evidence = [inventoryEvidence]
            if let prefix = tool.installPrefix { evidence.append(.knownLayout(prefix)) }
            ownership = Ownership(provider: entry.providerID, instance: entry.instanceID, packageName: tool.packageName, confidence: .confirmed, evidence: evidence)
        }

        let observedAt = entry.scannedAt
        let installedVersion = tool.activeVersion ?? VersionText.highest(tool.installedVersions)
        let version = installedVersion.map { ObservedValue(ToolVersion($0), source: .provider(entry.providerID), confidence: .confirmed, observedAt: observedAt) }
        var latest: ObservedValue<ToolVersion>?
        if let newest = tool.latestVersion {
            latest = ObservedValue(ToolVersion(newest), source: .provider(entry.providerID), confidence: .confirmed, observedAt: observedAt)
        } else if tool.isOutdated == false, let version {
            latest = version
        }

        return ToolInstallation(
            id: entry.installationID,
            ownership: ownership,
            version: version,
            latest: latest,
            executables: Self.sortedExecutables(executables),
            installPrefix: tool.installPrefix ?? supporting.first?.attribution.installPrefix,
            linkState: .notOnPath,
            isDirect: tool.isDirect ?? (tool.kind == .cask ? true : nil),
            isSystemManaged: false,
            dependencies: tool.dependencies,
            dependents: packages.dependents(of: entry),
            installedAt: tool.installedAt
        )
    }

    private func packageIdentity(_ entry: PackageIndex.Entry) -> ToolIdentity {
        let tool = entry.tool
        let direct = tool.isDirect ?? (entry.providerID != .homebrew || tool.kind == .cask)
        return ToolIdentity(
            name: tool.packageName,
            displayName: tool.displayName ?? tool.packageName,
            summary: tool.summary,
            category: direct ? .developerTool : .dependency,
            homepage: tool.homepage.flatMap { URL(string: $0) }
        )
    }

    // MARK: - Path-only installations

    struct PathGroupKey: Hashable {
        var toolID: ToolID
        var installationKey: String
        var identity: ToolIdentity
    }

    private static let packageProviders: Set<ProviderID> = [.homebrew, .npm, .uv, .pipx, .pnpm, .bun, .cargo, .go]

    private func groupPathOnly(_ items: [Located]) -> [PathGroupKey: [Located]] {
        // Unowned executables are grouped by the file they resolve to, but named after the
        // group's first PATH location: the resolved file of a self-updating tool carries its
        // version (`~/.grok/downloads/grok-1.0.25-…`), the location in PATH does not.
        var firstLocations: [String: Located] = [:]
        for item in items where item.attribution.ownership.provider == .standalone {
            let key = item.name + "\u{0}" + item.effectivePath
            if let current = firstLocations[key], Self.pathOrder(current) <= Self.pathOrder(item) { continue }
            firstLocations[key] = item
        }

        var groups: [PathGroupKey: [Located]] = [:]
        for item in items {
            let ownership = item.attribution.ownership
            let byName = registry.definition(forExecutable: item.name)
            let byLayout = item.attribution.layoutDefinitionID.flatMap { registry.definition($0) }
            if ownership.provider == .system && byName == nil { continue }

            let isPackage = Self.packageProviders.contains(ownership.provider) && ownership.packageName != nil
            let byPackage = isPackage ? ownership.packageName.flatMap { registry.definition(forPackage: $0, provider: ownership.provider) } : nil

            let toolID: ToolID
            let identity: ToolIdentity
            if let definition = byLayout ?? byPackage ?? byName {
                toolID = definition.id
                identity = definition.identity
            } else if isPackage, let package = ownership.packageName {
                toolID = Self.packageToolID(provider: ownership.provider, package: package)
                identity = ToolIdentity(name: package, displayName: package, category: .developerTool)
            } else if let formula = item.attribution.interpreterFormula {
                // One tool per script: each keeps its own command resolution, and the
                // formula in the id keeps it apart from a Homebrew package of the same name.
                toolID = ToolID("\(ownership.provider.rawValue).\(formula):\(item.name)")
                identity = ToolIdentity(name: item.name, displayName: item.name, category: .developerTool)
            } else if ownership.provider == .standalone {
                // Keyed by the resolved file, so `~/.local/bin/agent → ~/.grok/bin/agent`
                // and `~/.grok/bin/agent` (both in PATH) are one tool with two locations.
                let lead = firstLocations[item.name + "\u{0}" + item.effectivePath] ?? item
                toolID = Self.unknownToolID(name: item.name, location: lead.path)
                identity = ToolIdentity(name: item.name, displayName: item.name, category: .unrecognized)
            } else {
                toolID = ToolID("\(ownership.provider.rawValue).\(item.name)")
                identity = ToolIdentity(name: item.name, displayName: item.name, category: .developerTool)
            }

            let installationKey: String
            if isPackage, let package = ownership.packageName {
                installationKey = InstallationID.package(provider: ownership.provider, instance: ownership.instance, name: package).rawValue
            } else {
                let location = item.isBroken ? PathUtil.directory(of: item.path) : PathUtil.directory(of: item.effectivePath)
                installationKey = "\(ownership.provider.rawValue)|\(location)"
            }
            groups[PathGroupKey(toolID: toolID, installationKey: installationKey, identity: identity), default: []].append(item)
        }
        return groups
    }

    /// `unknown.<sha256(name + NUL + location)>` — stable across scans and upgrades (§114).
    /// `location` is the first PATH location of the command (e.g. `~/.grok/bin/grok`),
    /// never its resolved file, whose name may change with every release.
    public static func unknownToolID(name: String, location: String) -> ToolID {
        let digest = SHA256.hash(data: Data((name + "\u{0}" + PathUtil.trimmed(location)).utf8))
        let hex: [Character] = Array("0123456789abcdef")
        var id = "unknown."
        id.reserveCapacity(8 + 64)
        for byte in digest {
            id.append(hex[Int(byte >> 4)])
            id.append(hex[Int(byte & 0x0f)])
        }
        return ToolID(id)
    }

    /// `<provider>.<package>` for packages outside the registry. npm, pnpm and bun all
    /// install from the npm registry, so one package name is one tool across them, with an
    /// installation per provider: `npm.@opencode-ai/cli` for both `npm i -g` and `bun add -g`.
    static func packageToolID(provider: ProviderID, package: String) -> ToolID {
        let namespace = npmRegistryProviders.contains(provider) ? ProviderID.npm : provider
        return ToolID("\(namespace.rawValue).\(package)")
    }

    static let npmRegistryProviders: Set<ProviderID> = [.npm, .pnpm, .bun]

    static func pathOrder(_ item: Located) -> (Int, String) {
        (item.pathPriority ?? Int.max, item.path)
    }

    private func pathInstallation(_ items: [Located], definition: ToolDefinition?, now: Date) -> ToolInstallation {
        let ordered = items.sorted { ($0.pathPriority ?? Int.max, $0.path) < ($1.pathPriority ?? Int.max, $1.path) }
        let lead = ordered.first { !$0.isBroken } ?? ordered[0]
        // Name the installation after the tool's own command, not a bundled helper that sorts first.
        let anchor = definition.flatMap { definition in ordered.first { definition.executables.contains($0.name) } } ?? ordered[0]
        var ownership = lead.attribution.ownership
        for item in ordered {
            for evidence in item.attribution.ownership.evidence where !ownership.evidence.contains(evidence) {
                ownership.evidence.append(evidence)
            }
        }
        let isPackage = Self.packageProviders.contains(ownership.provider) && ownership.packageName != nil
        let id: InstallationID = isPackage
            ? .package(provider: ownership.provider, instance: ownership.instance, name: ownership.packageName ?? lead.name)
            : .path(anchor.path)
        let pathVersion = ordered.lazy.compactMap(\.attribution.pathVersion).first
        let manifestVersion = ordered.lazy.compactMap(\.attribution.manifestVersion).first
        let version = pathVersion.map { ObservedValue(ToolVersion($0), source: .path, confidence: .probable, observedAt: now) }
            ?? manifestVersion.map { ObservedValue(ToolVersion($0), source: .filesystem, confidence: .probable, observedAt: now) }
        return ToolInstallation(
            id: id,
            ownership: ownership,
            version: version,
            executables: Self.sortedExecutables(ordered.map(\.reference)),
            installPrefix: ordered.lazy.compactMap(\.attribution.installPrefix).first,
            linkState: .notOnPath,
            isDirect: nil,
            isSystemManaged: ownership.provider == .system
        )
    }

    static func sortedExecutables(_ executables: [ExecutableRef]) -> [ExecutableRef] {
        executables.uniqued().sorted { ($0.pathPriority ?? Int.max, $0.path) < ($1.pathPriority ?? Int.max, $1.path) }
    }

    // MARK: - Tools

    struct ToolDraft {
        var identity: ToolIdentity
        var installations: [ToolInstallation] = []
        var commandNames: [String] = []

        mutating func add(_ installation: ToolInstallation, names: [String]) {
            if let index = installations.firstIndex(where: { $0.id == installation.id }) {
                var existing = installations[index]
                existing.executables = MergeEngine.sortedExecutables(existing.executables + installation.executables)
                installations[index] = existing
            } else {
                installations.append(installation)
            }
            commandNames = (commandNames + names + installation.executables.map(\.name)).uniqued()
        }
    }

    private func buildTool(id: ToolID, draft: ToolDraft, discovery: DiscoveryResult, brokenPaths: Set<String>, services: [ToolService], now: Date) -> Tool {
        let definition = draft.identity.registryID.flatMap { registry.definition(ToolID($0)) }
        let names = ((definition?.executables ?? []) + draft.commandNames).uniqued()
        let command = names.first { !Self.workingCandidates(named: $0, in: discovery).isEmpty } ?? names.first ?? id.rawValue
        let chainCandidates = Self.workingCandidates(named: command, in: discovery)
        let chain = chainCandidates.map { ExecutableRef(name: $0.name, path: $0.path, resolvedPath: $0.resolvedPath, pathPriority: $0.pathPriority) }
        let resolution = CommandResolution(command: command, chain: chain, shadows: discovery.session.environment.shadows[command] ?? [])

        let activePath = chain.first?.path
        var installations = draft.installations.map { installation in
            var installation = installation
            installation.linkState = Self.linkState(of: installation, command: command, activePath: activePath, brokenPaths: brokenPaths, discovery: discovery)
            return installation
        }
        installations.sort(by: Self.installationOrder)
        let activeID = activePath.flatMap { path in installations.first { $0.executables.contains { $0.path == path } }?.id }
        installations = Self.presentationOrder(installations, activeID: activeID)

        let toolServices = services.filter { $0.toolID == id }
        let service = toolServices.first { $0.installationID == activeID && activeID != nil } ?? toolServices.first

        return Tool(
            id: id,
            identity: draft.identity,
            installations: installations,
            activeInstallationID: activeID,
            resolution: chain.isEmpty && resolution.shadows.isEmpty ? nil : resolution,
            service: service,
            health: ToolHealthState(status: .healthy),
            lastScannedAt: now
        )
    }

    static func linkState(of installation: ToolInstallation, command: String, activePath: String?, brokenPaths: Set<String>, discovery: DiscoveryResult) -> LinkState {
        let executables = installation.executables
        let working = executables.filter { !brokenPaths.contains($0.path) }
        if !executables.isEmpty && working.isEmpty { return .broken }
        let onPath = working.filter { $0.pathPriority != nil }
        if let activePath, onPath.contains(where: { $0.path == activePath }) { return .active }
        if onPath.contains(where: { $0.name == command }) { return .shadowed }
        guard !onPath.isEmpty else { return .notOnPath }
        let firstInGroup = onPath.contains { executable in
            workingCandidates(named: executable.name, in: discovery).first?.path == executable.path
        }
        return firstInGroup ? .active : .shadowed
    }

    static func installationOrder(_ lhs: ToolInstallation, _ rhs: ToolInstallation) -> Bool {
        func rank(_ state: LinkState) -> Int {
            switch state {
            case .active: 0
            case .shadowed: 1
            case .notOnPath: 2
            case .broken: 3
            }
        }
        func priority(_ installation: ToolInstallation) -> Int {
            installation.executables.compactMap(\.pathPriority).min() ?? Int.max
        }
        return (rank(lhs.linkState), priority(lhs), lhs.id.rawValue) < (rank(rhs.linkState), priority(rhs), rhs.id.rawValue)
    }

    /// Order installations are listed in: the one the terminal runs for the tool's
    /// command, then confirmed-ownership installations, then the rest, then
    /// system-managed ones (`/usr/bin/python3`). Within a group, newest version first;
    /// ties keep `installationOrder`. A helper that is merely first in its own
    /// PATH group (`python3.12`) no longer outranks the resolved `python3`.
    static func presentationOrder(_ installations: [ToolInstallation], activeID: InstallationID?) -> [ToolInstallation] {
        func group(_ installation: ToolInstallation) -> Int {
            if installation.id == activeID { return 0 }
            if installation.isSystemManaged { return 3 }
            return installation.ownership.confidence == .confirmed ? 1 : 2
        }
        return installations.sorted { lhs, rhs in
            let (left, right) = (group(lhs), group(rhs))
            if left != right { return left < right }
            if let newer = newerVersionFirst(lhs.version?.value, rhs.version?.value) { return newer }
            return installationOrder(lhs, rhs)
        }
    }

    /// `true`/`false` when the versions decide the order, `nil` for a tie. Parseable
    /// versions sort before unparseable ones, which sort before missing ones.
    static func newerVersionFirst(_ lhs: ToolVersion?, _ rhs: ToolVersion?) -> Bool? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (_?, nil): return true
        case (nil, _?): return false
        case let (left?, right?):
            switch (left.semantic, right.semantic) {
            case let (a?, b?): return a < b ? false : (b < a ? true : nil)
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return nil
            }
        }
    }

    // MARK: - Services

    private func mergeServices(inventories: [ProviderInventory], packages: PackageIndex) -> [ToolService] {
        var result: [String: ToolService] = [:]
        for inventory in inventories {
            for service in inventory.services {
                let id = "\(service.providerID.rawValue):\(service.name)"
                let entry = packages.entry(provider: service.providerID, packageName: service.name)
                result[id] = ToolService(
                    id: id, name: service.name, providerID: service.providerID, status: service.status, rawStatus: service.rawStatus,
                    toolID: entry?.toolID, installationID: entry?.installationID, user: service.user, plistPath: service.plistPath, exitCode: service.exitCode
                )
            }
        }
        return Array(result.values)
    }
}
