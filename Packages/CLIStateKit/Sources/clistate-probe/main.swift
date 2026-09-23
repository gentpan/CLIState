import CLIStateApplication
import CLIStateDiscovery
import CLIStateDomain
import CLIStateInfrastructure
import CLIStateProviders
import Foundation

// Headless probe for verifying CLIState's understanding of a real Mac without
// the UI (plan §5). Output redacts the home directory to `~`.

let usage = """
usage: clistate-probe <command>

  path            PATH entries as the login shell reports them
  which <name>    every PATH match for <name>, in resolution order
  shell           shell, source and shadowed registry commands
  providers [--deep]
                  Homebrew, npm and uv inventories (read-only; --deep checks for updates)
  cleanup         cleanup previews from provider dry runs (read-only)
  scan [--deep] [--all]
                  full snapshot: tools, installations, provenance
  explain <tool>  how CLIState understands one tool (id or command name)
  doctor [--deep] environment health and issues
  usage [--deep]  disk usage and last use per installation, and what measuring costs
  leftovers <tool>...
                  files each tool left in the home directory (read-only)
  diagnostics <dir>
                  write a redacted diagnostics bundle (and <dir>.zip)
  changes [--since 7d]
                  environment change timeline recorded by the app (read-only)
  profile export [file] | diff <file|template:<id>> | templates
                  environment restore: export, compare and list templates (read-only)
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(2)
}

if command == "diagnostics" {
    guard arguments.count == 2 else { print(usage); exit(2) }
    let environment = AppEnvironment.live(inMemoryPersistence: true)
    let snapshot = await environment.scan.scan(depth: .fast)
    let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let exporter = DiagnosticsExporter(context: .current(appVersion: "probe", build: "dev"))
    let files = try exporter.write(snapshot: snapshot, history: [], to: directory)
    let archive = directory.appendingPathExtension("zip")
    try await DiagnosticsExporter.zip(directory: directory, to: archive, runner: environment.runner)
    print(files.map(\.lastPathComponent).joined(separator: "\n"))
    print("archive \(archive.path)")
    exit(0)
}

if command == "usage" {
    await runUsageCommand(Array(arguments.dropFirst()))
    exit(0)
}

if command == "changes" {
    runChangesCommand(Array(arguments.dropFirst()))
    exit(0)
}

if command == "profile" {
    exit(try await runProfileCommand(Array(arguments.dropFirst())))
}

if command == "leftovers" {
    guard arguments.count >= 2 else { print(usage); exit(2) }
    let environment = AppEnvironment.live(inMemoryPersistence: true)
    _ = await environment.scan.scan(depth: .fast)
    let home = environment.fileSystem.homeDirectory
    for name in arguments.dropFirst() {
        print(name)
        for item in await environment.operations.leftovers(for: ToolID(name)) {
            let size = item.sizeBytes.formatted(.byteCount(style: .file))
            print("  \(item.kind.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(item.sizeIsLowerBound ? ">=" : "  ")\(size.padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.origin.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(PathRedaction.abbreviatingHome(item.path, home: home))")
        }
    }
    exit(0)
}

if ["scan", "explain", "doctor"].contains(command) {
    try await runSnapshotCommand(command, arguments: Array(arguments.dropFirst()))
    exit(0)
}

let fileSystem = LocalFileSystem()
let runner = ProcessCommandRunner()
let home = fileSystem.homeDirectory
func tilde(_ path: String) -> String { PathRedaction.abbreviatingHome(path, home: home) }

let discovery = EnvironmentDiscovery(runner: runner, fileSystem: fileSystem, shadowCandidates: ["node", "python3", "php", "claude", "npm", "git", "ruby", "java"])
let clock = ContinuousClock()
let start = clock.now
let result = try await discovery.discover()
let elapsed = clock.now - start

switch command {
case "path":
    let environment = result.session.environment
    print("shell   \(environment.shell.executable) (\(environment.source.rawValue)) · \(result.binaries.executableCount) executables · \(result.binaries.brokenSymlinks.count) broken links · \(elapsed.formatted(.units(allowed: [.milliseconds])))")
    for entry in result.pathEntries {
        var status = entry.status.rawValue
        if let original = entry.duplicateOf { status += " of #\(original)" }
        let count = entry.status == .ok ? String(entry.executableCount) : "-"
        let columns = [
            String(entry.priority).leftPadded(to: 3),
            status.padding(toLength: 16, withPad: " ", startingAt: 0),
            entry.source.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0),
            count.leftPadded(to: 4),
            tilde(entry.rawValue),
        ]
        print(columns.joined(separator: "  "))
    }

case "which":
    guard arguments.count == 2 else {
        print(usage)
        exit(2)
    }
    let name = arguments[1]
    let candidates = result.binaries.candidates(named: name)
    if candidates.isEmpty { print("\(name): not found"); exit(1) }
    for (index, candidate) in candidates.enumerated() {
        let marker = index == 0 ? "active  " : "shadowed"
        let resolved = candidate.resolvedPath.map { $0 == candidate.path ? "" : " → \(tilde($0))" } ?? " → (broken)"
        print("#\(candidate.pathPriority)\t\(marker)  \(tilde(candidate.path))\(resolved)")
    }
    for shadow in result.session.environment.shadows[name] ?? [] {
        print("shell   \(shadow.kind.rawValue) \(shadow.name) runs before any PATH lookup")
    }

case "shell":
    let environment = result.session.environment
    print("shell    \(environment.shell.executable)")
    print("source   \(environment.source.rawValue)\(environment.failureReason.map { " (\($0))" } ?? "")")
    print("persisted variables: \(environment.variables.keys.sorted().joined(separator: ", "))")
    let shadows = environment.shadows.sorted { $0.key < $1.key }
    print(shadows.isEmpty ? "no shell aliases or functions shadow registry commands" : shadows.map { "\($0.key): \($0.value.map(\.kind.rawValue).joined(separator: ", "))" }.joined(separator: "\n"))

case "providers", "cleanup":
    let context = ProviderContext(discovery: result, now: Date())
    let providers: [any ToolProvider] = [
        HomebrewProvider(runner: runner, fileSystem: fileSystem),
        NPMProvider(runner: runner, fileSystem: fileSystem),
        UVProvider(runner: runner, fileSystem: fileSystem),
        PipxProvider(runner: runner, fileSystem: fileSystem),
        PNPMProvider(runner: runner, fileSystem: fileSystem),
        CargoProvider(runner: runner, fileSystem: fileSystem),
    ]
    let depth: ScanDepth = arguments.contains("--deep") ? .deep : .fast
    for provider in providers {
        let availability = await provider.availability(context: context)
        guard availability.isAvailable else {
            print("\(provider.id): unavailable (\(availability.reason ?? "-"))")
            continue
        }
        if command == "cleanup" {
            guard let cleanup = provider as? any CleanupProvider else { continue }
            let started = clock.now
            do {
                for candidate in try await cleanup.cleanupCandidates(context: context) {
                    let size = candidate.reclaimableBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
                    print("\(provider.id)  \(candidate.kind.rawValue)  risk=\(candidate.risk.rawValue)  \(size)  items=\(candidate.items.count)  plan=\(candidate.plan?.steps.map(\.displayString).joined(separator: " && ") ?? "-")")
                }
            } catch {
                print("\(provider.id): cleanup preview failed: \(error)")
            }
            print("  (\((clock.now - started).formatted(.units(allowed: [.milliseconds]))))")
            continue
        }
        let started = clock.now
        do {
            let inventory = try await provider.scan(context: context, depth: depth)
            let tools = inventory.tools
            let outdated = tools.filter { $0.isOutdated == true || ($0.latestVersion != nil && $0.latestVersion != $0.activeVersion) }
            print("\(provider.id) \(availability.version ?? "") · \(tools.count) packages · \(tools.filter { $0.isDirect == true }.count) direct · \(outdated.count) outdated · \(inventory.services.count) services · \((clock.now - started).formatted(.units(allowed: [.milliseconds])))")
            for (key, value) in inventory.layout.roots.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                print("  \(key.rawValue): \(tilde(value))")
            }
            for tool in tools where tool.isDirect != false {
                let latest = tool.latestVersion.map { $0 == tool.activeVersion ? "" : " → \($0)" } ?? ""
                print("  \(tool.kind == .cask ? "cask " : "")\(tool.packageName) \(tool.activeVersion ?? tool.installedVersions.last ?? "?")\(latest)  [\(tool.executableNames.prefix(4).joined(separator: " "))]")
            }
            for service in inventory.services {
                print("  service \(service.name): \(service.status.rawValue)")
            }
            for warning in inventory.warnings.prefix(3) { print("  warning: \(warning)") }
        } catch {
            print("\(provider.id): scan failed: \(error)")
        }
    }

default:
    print(usage)
    exit(2)
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

// MARK: - Snapshot commands

func runSnapshotCommand(_ command: String, arguments: [String]) async throws {
    let environment = AppEnvironment.live(inMemoryPersistence: true)
    let home = environment.fileSystem.homeDirectory
    func tilde(_ path: String?) -> String { path.map { PathRedaction.abbreviatingHome($0, home: home) } ?? "-" }
    let deep = arguments.contains("--deep") || command == "explain"
    let clock = ContinuousClock()
    let started = clock.now
    guard let snapshot = await environment.scan.scan(depth: deep ? .deep : .fast) else {
        print("scan failed"); exit(1)
    }
    let elapsed = (clock.now - started).formatted(.units(allowed: [.seconds, .milliseconds]))

    func version(_ installation: ToolInstallation) -> String {
        let current = installation.version?.value.rawValue ?? "?"
        guard installation.hasUpdate, let latest = installation.latest?.value.rawValue else { return current }
        return "\(current) → \(latest)\(installation.latestChannel.map { " (\($0))" } ?? "")"
    }

    switch command {
    case "scan":
        let showAll = arguments.contains("--all")
        let counts = Dictionary(grouping: snapshot.tools, by: \.identity.category).mapValues(\.count)
        print("snapshot \(snapshot.depth.rawValue) · \(elapsed) · \(snapshot.tools.count) tools · \(snapshot.issues.count) issues · health \(snapshot.health.rawValue)")
        print(ToolCategory.allCases.map { "\($0.rawValue) \(counts[$0, default: 0])" }.joined(separator: " · "))
        for category in ToolCategory.allCases where showAll || ![.dependency, .unrecognized].contains(category) {
            let tools = snapshot.tools.filter { $0.identity.category == category }
            guard !tools.isEmpty else { continue }
            print("\n[\(category.rawValue)]")
            for tool in tools {
                let primary = tool.primaryInstallation
                let via = primary.map { "\($0.ownership.provider.rawValue)/\($0.ownership.confidence.rawValue)" } ?? "-"
                let extra = tool.installations.count > 1 ? "  +\(tool.installations.count - 1) more" : ""
                let status = tool.health.status == .healthy ? "" : "  <\(tool.health.status.rawValue)>"
                print("  \(tool.identity.displayName.padding(toLength: 22, withPad: " ", startingAt: 0)) \(primary.map(version) ?? "-")  via \(via)\(extra)\(status)")
            }
        }

    case "explain":
        guard let query = arguments.first(where: { !$0.hasPrefix("--") }) else { print("usage: clistate-probe explain <tool>"); exit(2) }
        let matches = snapshot.tools.filter { tool in
            tool.id.rawValue == query || tool.identity.name == query || tool.resolution?.command == query
                || tool.installations.contains { $0.executables.contains { $0.name == query } }
        }
        guard !matches.isEmpty else { print("\(query): not found in snapshot"); exit(1) }
        for tool in matches {
            print("\(tool.identity.displayName)  [\(tool.id.rawValue)] · \(tool.identity.category.rawValue) · \(tool.health.status.rawValue)")
            if let summary = tool.identity.summary { print("  \(summary)") }
            if let resolution = tool.resolution {
                print("  resolves `\(resolution.command)`:")
                for (index, ref) in resolution.chain.enumerated() {
                    let arch = ref.architecture.map { " \($0.rawValue)" } ?? ""
                    print("    #\(ref.pathPriority.map(String.init) ?? "?") \(index == 0 ? "active  " : "shadowed") \(tilde(ref.path))\(ref.resolvedPath.map { $0 == ref.path ? "" : " → " + tilde($0) } ?? " → (broken)")\(arch)")
                }
                for shadow in resolution.shadows { print("    shell \(shadow.kind.rawValue) runs first") }
            }
            for installation in tool.installations {
                let active = installation.id == tool.activeInstallationID ? " ← active" : ""
                print("  installation \(installation.id.rawValue)\(active)")
                print("    via \(installation.ownership.provider.rawValue) · \(installation.ownership.confidence.rawValue) · \(installation.linkState.rawValue)\(installation.isSystemManaged ? " · system managed" : "")\(installation.isDirect == false ? " · dependency" : "")")
                if let observed = installation.version {
                    print("    version \(version(installation))  (source: \(observed.source))")
                }
                if let prefix = installation.installPrefix { print("    prefix \(tilde(prefix))") }
                if installation.diskUsage != nil || installation.lastUsedAt != nil {
                    let size = installation.diskUsage.map { "\($0.isPartial ? ">= " : "")\($0.bytes.formatted(.byteCount(style: .file)))" } ?? "-"
                    let used = installation.lastUsedAt.map { $0.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.colon)) } ?? "-"
                    print("    disk \(size) · last used \(used)")
                }
                if let support = installation.support {
                    print("    support \(support.product) \(support.cycle): \(support.phase.rawValue)\(support.endOfLifeDate.map { " (eol \($0.formatted(.iso8601.year().month().day())))" } ?? "")\(support.latestSupportedCycle.map { " · latest supported \($0)" } ?? "")")
                }
                let evidence = installation.ownership.evidence.map { "\($0)" }.map { PathRedaction.abbreviatingHome($0, home: home) }
                if !evidence.isEmpty { print("    evidence \(evidence.joined(separator: "; "))") }
                let caps = installation.capabilities
                let allowed = [("update", caps.canUpdate), ("uninstall", caps.canUninstall), ("start/stop", caps.canStart), ("trash", caps.canMoveToTrash)].filter(\.1).map(\.0)
                print("    can \(allowed.isEmpty ? "nothing (read-only)" : allowed.joined(separator: ", "))")
                if !installation.dependents.isEmpty { print("    used by \(installation.dependents.joined(separator: ", "))") }
                if !installation.configPaths.isEmpty { print("    config \(installation.configPaths.map { tilde($0) }.joined(separator: ", "))") }
            }
            if let service = tool.service { print("  service \(service.name): \(service.status.rawValue)") }
            for issue in snapshot.issues where issue.toolID == tool.id {
                print("  issue [\(issue.severity.rawValue)] \(issue.type.rawValue): \(issue.subject)")
            }
            print("")
        }

    case "doctor":
        print("health \(snapshot.health.rawValue) · \(snapshot.issues.count) issues · scanned in \(elapsed)")
        for provider in snapshot.providers {
            print("  provider \(provider.providerID.rawValue): \(provider.availability.isAvailable ? "available" : "unavailable") · \(provider.toolCount) packages · \(provider.freshness)")
        }
        for severity in [HealthSeverity.critical, .warning, .info] {
            for issue in snapshot.issues where issue.severity == severity {
                let paths = issue.paths.prefix(3).map { tilde($0) }.joined(separator: ", ")
                print("  [\(severity.rawValue)] \(issue.type.rawValue): \(tilde(issue.subject))\(paths.isEmpty ? "" : "  (\(paths)\(issue.paths.count > 3 ? ", +\(issue.paths.count - 3)" : ""))")")
            }
        }
        print("  cleanup candidates (engine): \(snapshot.cleanupCandidates.count)")

    default:
        break
    }
}
