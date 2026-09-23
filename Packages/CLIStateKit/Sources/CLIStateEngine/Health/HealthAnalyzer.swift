import CLIStateDomain
import Foundation

/// Health rules and severities from plan §6.7. Updates are never issues (C7),
/// and duplicates of system shims are not reported (F13).
public struct HealthAnalyzer: Sendable {
    public let registry: ToolRegistry
    public let hostArchitecture: CPUArchitecture

    public init(registry: ToolRegistry = .standard, hostArchitecture: CPUArchitecture = .host) {
        self.registry = registry
        self.hostArchitecture = hostArchitecture
    }

    /// Returns issues sorted by severity (worst first) then id, and the tools with
    /// their `ToolHealthState` filled in.
    public func analyze(
        tools: [Tool],
        discovery: DiscoveryResult,
        brokenSymlinks: [BrokenSymlink],
        services: [ToolService],
        failedProviders: [ProviderID: String]
    ) -> (issues: [HealthIssue], tools: [Tool]) {
        var collector = IssueCollector()
        pathIssues(discovery.pathEntries, into: &collector)
        brokenLinkIssues(brokenSymlinks, tools: tools, into: &collector)
        missingRuntimeIssues(discovery: discovery, tools: tools, into: &collector)
        let brokenPaths = Set(brokenSymlinks.map(\.path))
        for tool in tools {
            toolIssues(tool, brokenPaths: brokenPaths, into: &collector)
        }
        collector.dropBrokenLinksExplainedByTools()
        for service in services where service.status == .error {
            var details: [String: String] = [:]
            if let exitCode = service.exitCode { details["exitCode"] = String(exitCode) }
            if let rawStatus = service.rawStatus { details["status"] = rawStatus }
            collector.add(HealthIssue(
                type: .failedService, severity: .critical, subject: service.name, toolID: service.toolID,
                installationIDs: service.installationID.map { [$0] } ?? [], paths: service.plistPath.map { [$0] } ?? [],
                details: details, suggestedAction: .restartService(service.name)
            ))
        }
        for (provider, reason) in failedProviders {
            collector.add(HealthIssue(type: .providerScanFailed, severity: .warning, subject: provider.rawValue, details: ["reason": reason]))
        }

        let issues = collector.sorted()
        let byTool = Dictionary(grouping: issues.filter { $0.toolID != nil }) { $0.toolID! }
        let updatedTools = tools.map { tool in
            var tool = tool
            tool.health = healthState(for: tool, issues: byTool[tool.id] ?? [])
            return tool
        }
        return (issues, updatedTools)
    }

    // MARK: PATH

    private func pathIssues(_ entries: [PATHEntry], into collector: inout IssueCollector) {
        for entry in entries.sorted(by: { $0.priority < $1.priority }) {
            let details = ["priority": String(entry.priority), "status": entry.status.rawValue]
            switch entry.status {
            case .missing, .notDirectory:
                // Cryptex mount points and /System entries come from path_helper and
                // appear only when macOS mounts them (F3); nothing for the user to fix.
                let severity: HealthSeverity = AttributionEngine.isOperatingSystemLocation(entry.normalizedPath) ? .info : .warning
                collector.add(HealthIssue(type: .missingPathEntry, severity: severity, subject: entry.normalizedPath.isEmpty ? entry.rawValue : entry.normalizedPath,
                                          paths: [entry.rawValue], details: details, suggestedAction: .openPathSettings))
            case .relative, .empty:
                collector.add(HealthIssue(type: .relativePathEntry, severity: .warning, subject: entry.rawValue.isEmpty ? "." : entry.rawValue,
                                          paths: [entry.rawValue], details: details, suggestedAction: .openPathSettings))
            case .duplicate:
                var duplicateDetails = details
                if let original = entry.duplicateOf { duplicateDetails["duplicateOf"] = String(original) }
                collector.add(HealthIssue(type: .duplicatePathEntry, severity: .info, subject: entry.normalizedPath,
                                          paths: [entry.rawValue], details: duplicateDetails, suggestedAction: .openPathSettings))
            case .ok, .protectedLocation, .unreadable:
                break
            }
        }
    }

    // MARK: Broken links

    private func brokenLinkIssues(_ links: [BrokenSymlink], tools: [Tool], into collector: inout IssueCollector) {
        var owners: [String: (ToolID, InstallationID)] = [:]
        for tool in tools {
            for installation in tool.installations {
                for executable in installation.executables where owners[executable.path] == nil {
                    owners[executable.path] = (tool.id, installation.id)
                }
            }
        }
        for link in links {
            let owner = owners[link.path]
            // SIP-protected links (e.g. /usr/sbin/weakpass_edit) are Apple's to fix.
            let severity: HealthSeverity = AttributionEngine.isSystemLocation(link.path) ? .info : .warning
            collector.add(HealthIssue(
                type: .brokenSymlink, severity: severity, subject: link.path, toolID: owner?.0,
                installationIDs: owner.map { [$0.1] } ?? [], paths: [link.path, link.absoluteDestination],
                details: ["destination": link.destination], suggestedAction: .revealInFinder(link.path)
            ))
        }
    }

    // MARK: Missing runtimes

    private func missingRuntimeIssues(discovery: DiscoveryResult, tools: [Tool], into collector: inout IssueCollector) {
        for definition in registry.definitions {
            guard let runtime = definition.requiredRuntime else { continue }
            let command = definition.primaryExecutable
            let candidates = MergeEngine.workingCandidates(named: command, in: discovery)
            guard let active = candidates.first, MergeEngine.workingCandidates(named: runtime, in: discovery).isEmpty else { continue }
            // A shell function/alias (e.g. nvm's lazy-loading `node()`) still provides the runtime (F4).
            let shadows = discovery.session.environment.shadows[runtime] ?? []
            guard !shadows.contains(where: { $0.kind == .function || $0.kind == .alias }) else { continue }
            let owner = tools.first { $0.installations.contains { $0.executables.contains { $0.path == active.path } } }
            collector.add(HealthIssue(
                type: .missingRuntime, severity: .warning, subject: command, toolID: owner?.id,
                installationIDs: owner?.installations.filter { $0.executables.contains { $0.path == active.path } }.map(\.id) ?? [],
                paths: [active.path], details: ["runtime": runtime]
            ))
        }
    }

    // MARK: Per tool

    private func toolIssues(_ tool: Tool, brokenPaths: Set<String>, into collector: inout IssueCollector) {
        let installations = tool.installations
        let onPath = installations.filter { $0.linkState == .active || $0.linkState == .shadowed }

        let brokenInventoryInstallations = installations.filter { installation in
            installation.linkState == .broken && installation.ownership.evidence.contains { if case .inventoryContains = $0 { true } else { false } }
        }
        if onPath.isEmpty, !brokenInventoryInstallations.isEmpty {
            // Critical means the environment can't run code or install packages (§149);
            // a menu-bar app's lost CLI helper is a warning.
            let essential: Set<ToolCategory> = [.runtime, .packageManager]
            collector.add(HealthIssue(
                type: .brokenActiveExecutable, severity: essential.contains(tool.identity.category) ? .critical : .warning,
                subject: tool.id.rawValue, toolID: tool.id,
                installationIDs: brokenInventoryInstallations.map(\.id),
                paths: brokenInventoryInstallations.flatMap { $0.executables.map(\.path) }
            ))
        }

        let competing = onPath.filter { !$0.isSystemManaged }
        func owner(_ installation: ToolInstallation) -> String {
            "\(installation.ownership.provider.rawValue)|\(installation.ownership.instance?.rawValue ?? "")"
        }
        if Set(competing.map(owner)).count >= 2 {
            // Owners only compete when they put the same command name in PATH; Kimi Code's
            // `kimi` next to uv's `kimi-cli` are two installations, not a conflict.
            var ownersByCommand: [String: Set<String>] = [:]
            for installation in competing {
                for executable in installation.executables where executable.pathPriority != nil && !brokenPaths.contains(executable.path) {
                    ownersByCommand[executable.name, default: []].insert(owner(installation))
                }
            }
            let contested = Set(ownersByCommand.filter { $0.value.count >= 2 }.keys)
            let providers = competing.map(\.ownership.provider.rawValue).uniqued()
            if !contested.isEmpty {
                let conflicting = competing.filter { installation in
                    installation.executables.contains { $0.pathPriority != nil && contested.contains($0.name) }
                }
                collector.add(HealthIssue(
                    type: .pathConflict, severity: .warning, subject: tool.id.rawValue, toolID: tool.id,
                    installationIDs: conflicting.map(\.id),
                    paths: conflicting.compactMap { installation in
                        installation.executables.first { $0.pathPriority != nil && contested.contains($0.name) }?.path
                    },
                    details: ["providers": conflicting.map(\.ownership.provider.rawValue).uniqued().joined(separator: ","),
                              "commands": contested.sorted().joined(separator: ","),
                              "active": tool.activeInstallationID?.rawValue ?? ""],
                    suggestedAction: .openPathSettings
                ))
            } else {
                collector.add(HealthIssue(
                    type: .duplicateInstallation, severity: .info, subject: tool.id.rawValue, toolID: tool.id,
                    installationIDs: competing.map(\.id),
                    details: ["providers": providers.joined(separator: ","), "versions": competing.compactMap { $0.version?.value.rawValue }.joined(separator: ",")]
                ))
            }
        }

        let managed = installations.filter { !$0.isSystemManaged && $0.linkState != .broken }
        for (provider, group) in Dictionary(grouping: managed, by: \.ownership.provider) where group.count >= 2 {
            collector.add(HealthIssue(
                type: .duplicateInstallation, severity: .info, subject: tool.id.rawValue, toolID: tool.id,
                installationIDs: group.map(\.id),
                details: ["provider": provider.rawValue, "versions": group.compactMap { $0.version?.value.rawValue }.joined(separator: ",")]
            ))
        }

        let architectures = Set(installations.flatMap { $0.executables.compactMap(\.architecture) })
        if architectures.contains(.x86_64), hostArchitecture == .arm64 || architectures.contains(.arm64) {
            collector.add(HealthIssue(
                type: .mixedArchitecture, severity: .info, subject: tool.id.rawValue, toolID: tool.id,
                installationIDs: installations.filter { $0.executables.contains { $0.architecture == .x86_64 } }.map(\.id),
                details: ["architectures": architectures.map(\.rawValue).sorted().joined(separator: ","), "host": hostArchitecture.rawValue]
            ))
        }

        if let resolution = tool.resolution {
            let shadows = resolution.shadows.filter { $0.kind == .alias || $0.kind == .function }
            if let first = shadows.first {
                var details = ["kind": first.kind.rawValue]
                if let detail = first.detail { details["detail"] = detail }
                collector.add(HealthIssue(type: .shellShadowing, severity: .info, subject: resolution.command, toolID: tool.id, details: details))
            }
        }
    }

    private func healthState(for tool: Tool, issues: [HealthIssue]) -> ToolHealthState {
        let ids = issues.map(\.id).sorted()
        let types = Set(issues.map(\.type))
        let status: ToolHealth
        if issues.contains(where: { $0.severity == .critical })
            || (!tool.installations.isEmpty && tool.installations.allSatisfy { $0.linkState == .broken }) {
            status = .broken
        } else if types.contains(.pathConflict) {
            status = .pathConflict
        } else if types.contains(.duplicateInstallation) {
            status = .duplicateInstallation
        } else if tool.hasUpdate {
            status = .updateAvailable
        } else if tool.identity.category == .unrecognized {
            status = .unknown
        } else {
            status = .healthy
        }
        return ToolHealthState(status: status, issueIDs: ids)
    }
}

/// Deduplicates by stable id, merging affected paths and installations.
private struct IssueCollector {
    private var issues: [String: HealthIssue] = [:]

    mutating func add(_ issue: HealthIssue) {
        guard var existing = issues[issue.id] else {
            issues[issue.id] = issue
            return
        }
        existing.paths = (existing.paths + issue.paths).uniqued()
        existing.installationIDs = (existing.installationIDs + issue.installationIDs).uniqued()
        existing.severity = max(existing.severity, issue.severity)
        issues[issue.id] = existing
    }

    /// "CodexBar can't run" already names its broken link; a second "Broken link:
    /// codexbar" issue for the same path only repeats it.
    /// The link's destination moves to the tool issue so the detail isn't lost.
    mutating func dropBrokenLinksExplainedByTools() {
        let links = issues.values.filter { $0.type == .brokenSymlink }
        for toolIssue in issues.values where toolIssue.type == .brokenActiveExecutable {
            var merged = toolIssue
            for link in links where toolIssue.paths.contains(link.subject) {
                merged.paths = (merged.paths + link.paths).uniqued()
                merged.details.merge(link.details) { current, _ in current }
                issues[link.id] = nil
            }
            issues[toolIssue.id] = merged
        }
    }

    func sorted() -> [HealthIssue] {
        issues.values.sorted { ($0.severity, $1.id) > ($1.severity, $0.id) }
    }
}
