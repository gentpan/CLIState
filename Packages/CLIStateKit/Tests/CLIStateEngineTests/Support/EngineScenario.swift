import CLIStateDomain
import CLIStateEngine
import CLIStateTestSupport
import Foundation

let home = "/Users/tester"
let scanDate = Date(timeIntervalSince1970: 1_789_000_000)

/// A PATH modeled on the reference machine (plan F3), so priorities match the
/// scenarios: `~/.kimi-code/bin` is #4, `~/.local/bin` #10, `/opt/homebrew/bin` #11.
let referencePATH = [
    "\(home)/Library/Application Support/Herd/bin/",
    "\(home)/.mavis/bin",
    "\(home)/.cargo/bin",
    "\(home)/.kimi-code/bin",
    "\(home)/.grok/bin",
    "\(home)/.bun/bin",
    "\(home)/.deno/bin",
    "\(home)/.opencode/bin",
    "\(home)/.lmstudio/bin",
    "\(home)/.local/bin",
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "/System/Cryptexes/App/usr/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
]

/// Builds discovery results from an `InMemoryFileSystem` the way discovery does:
/// PATH order, lstat + realpath, broken links collected separately.
final class EngineScenario: @unchecked Sendable {
    let fs = InMemoryFileSystem(home: home)
    let runner = StubCommandRunner()
    var path: [String]
    var shadows: [String: [ShellShadow]] = [:]
    var variables: [String: String] = [:]

    init(path: [String] = referencePATH, createDirectories: Bool = true) {
        self.path = path
        if createDirectories {
            for entry in path where entry.hasPrefix("/") { fs.addDirectory(entry) }
        }
        // Developer tools and a JDK are present unless a test says otherwise.
        runner.stub("xcode-select", ["-p"], stdout: "/Library/Developer/CommandLineTools\n")
        runner.stub("java_home", [], stdout: "/Library/Java/JavaVirtualMachines/jdk/Contents/Home\n")
    }

    // MARK: Filesystem helpers

    func executable(_ path: String, contents: String = "#!/bin/sh\n") {
        fs.addExecutable(path, contents: contents)
    }

    func binary(_ path: String, header: [UInt8]) {
        fs.addFile(path, contents: Data(header), executable: true)
    }

    /// Stores relative destinations made absolute lexically. `InMemoryFileSystem`
    /// normalizes with `standardizingPath`, which resolves `..` against the *host*
    /// disk and breaks links on machines that really have Homebrew installed.
    func link(_ path: String, to destination: String) {
        guard !destination.hasPrefix("/") else { return fs.addSymlink(path, to: destination) }
        var parts = (path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for component in destination.split(separator: "/").map(String.init) {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        fs.addSymlink(path, to: "/" + parts.joined(separator: "/"))
    }

    /// Keeps the destination string exactly as given (for broken-link attribution tests).
    func rawLink(_ path: String, to destination: String) {
        fs.addSymlink(path, to: destination)
    }

    // MARK: Discovery

    func discovery() -> DiscoveryResult {
        var entries: [PATHEntry] = []
        var seen: [String: Int] = [:]
        var groups: [String: [BinaryCandidate]] = [:]
        var broken: [BrokenSymlink] = []

        for (index, raw) in path.enumerated() {
            let priority = index + 1
            var normalized = raw.hasPrefix("~/") ? home + raw.dropFirst(1) : raw
            while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
            var status = PATHEntryStatus.ok
            var duplicateOf: Int?
            if raw.isEmpty {
                status = .empty
            } else if !normalized.hasPrefix("/") {
                status = .relative
            } else if let first = seen[normalized] {
                status = .duplicate
                duplicateOf = first
            } else if !fs.exists(atPath: normalized) {
                status = .missing
            } else if !fs.isDirectory(atPath: normalized) {
                status = .notDirectory
            }

            var count = 0
            if status == .ok {
                seen[normalized] = priority
                let names = ((try? fs.contentsOfDirectory(atPath: normalized)) ?? []).sorted()
                for name in names {
                    let candidatePath = normalized + "/" + name
                    guard let attributes = fs.attributes(atPath: candidatePath) else { continue }
                    if attributes.kind == .symlink {
                        guard let resolved = fs.resolvingSymlinks(atPath: candidatePath) else {
                            let destination = (try? fs.destinationOfSymbolicLink(atPath: candidatePath)) ?? ""
                            broken.append(BrokenSymlink(path: candidatePath, destination: destination, pathPriority: priority))
                            continue
                        }
                        guard fs.isExecutableFile(atPath: candidatePath) else { continue }
                        let target = fs.attributes(atPath: resolved)
                        groups[name, default: []].append(BinaryCandidate(name: name, path: candidatePath, pathPriority: priority, isSymlink: true, resolvedPath: resolved, size: target?.size, modifiedAt: target?.modifiedAt))
                        count += 1
                    } else if attributes.kind == .file, attributes.isExecutable {
                        groups[name, default: []].append(BinaryCandidate(name: name, path: candidatePath, pathPriority: priority, isSymlink: false, resolvedPath: fs.resolvingSymlinks(atPath: candidatePath), size: attributes.size, modifiedAt: attributes.modifiedAt))
                        count += 1
                    }
                }
            }
            entries.append(PATHEntry(priority: priority, rawValue: raw, normalizedPath: normalized, status: status, source: .unknown, isWritable: true, executableCount: count, duplicateOf: duplicateOf))
        }

        let environment = ShellEnvironment(
            shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh),
            path: path,
            variables: ["HOME": home, "PATH": path.joined(separator: ":")].merging(variables) { _, new in new },
            shadows: shadows,
            source: .loginShell,
            capturedAt: scanDate
        )
        let execution = ExecutionEnvironment(variables: environment.variables)
        return DiscoveryResult(
            session: ShellSession(environment: environment, execution: execution),
            pathEntries: entries,
            binaries: BinaryInventory(groups: groups.mapValues { BinaryGroup(executableName: $0[0].name, candidates: $0) }, brokenSymlinks: broken)
        )
    }

    // MARK: Engine

    /// Usage policy for every build; tests about disk usage change it.
    var diskUsagePolicy = DiskUsagePolicy.standard

    /// `clock` defaults to the scan's `now`, so probe times and access windows are deterministic.
    func engine(updateSources: [any UpdateSource]? = nil, host: CPUArchitecture = .arm64, clock: (@Sendable () -> Date)? = nil) -> SnapshotEngine {
        SnapshotEngine(fileSystem: fs, commandRunner: runner, updateSources: updateSources, hostArchitecture: host, diskUsagePolicy: diskUsagePolicy, clock: clock ?? { scanDate })
    }

    func build(
        inventories: [ProviderInventory] = [],
        failed: [ProviderID: String] = [:],
        previous: EnvironmentSnapshot? = nil,
        depth: ScanDepth = .fast,
        updateSources: [any UpdateSource]? = nil,
        now: Date = scanDate,
        clock: (@Sendable () -> Date)? = nil
    ) async -> EnvironmentSnapshot {
        await engine(updateSources: updateSources, clock: clock ?? { now }).buildSnapshot(
            discovery: discovery(), inventories: inventories, failedProviders: failed, previous: previous, depth: depth, now: now
        )
    }

    /// Executables the stub runner was asked to run, by file name.
    var probedNames: [String] {
        runner.invocations.map { ($0.command.executable as NSString).lastPathComponent }
    }
}

// MARK: Inventory builders

func homebrewInventory(_ tools: [ProviderTool], services: [ProviderService] = [], depth: ScanDepth = .fast, at date: Date = scanDate) -> ProviderInventory {
    ProviderInventory(
        providerID: .homebrew,
        availability: ProviderAvailability(providerID: .homebrew, isAvailable: true, executable: "/opt/homebrew/bin/brew", version: "6.0.22"),
        layout: ProviderLayout(roots: [.homebrewPrefix: "/opt/homebrew", .homebrewCellar: "/opt/homebrew/Cellar", .homebrewCaskroom: "/opt/homebrew/Caskroom"]),
        tools: tools,
        services: services,
        depth: depth,
        scannedAt: date
    )
}

func formula(_ name: String, _ version: String, latest: String? = nil, direct: Bool? = true, kegOnly: Bool = false, executables: [String] = [], paths: [String] = [], dependencies: [String] = []) -> ProviderTool {
    ProviderTool(
        providerID: .homebrew, packageName: name, kind: .formula,
        installedVersions: [version], activeVersion: kegOnly ? nil : version, latestVersion: latest,
        isOutdated: latest.map { $0 != version },
        installPrefix: "/opt/homebrew/Cellar/\(name)/\(version)",
        executableNames: executables, executablePaths: paths,
        isDirect: direct, isKegOnly: kegOnly, dependencies: dependencies
    )
}

func npmInventory(root: String, _ tools: [ProviderTool], depth: ScanDepth = .fast, at date: Date = scanDate) -> ProviderInventory {
    let instance = ProviderInstanceID("npm@\(root)")
    return ProviderInventory(
        providerID: .npm,
        availability: ProviderAvailability(providerID: .npm, isAvailable: true, executable: "\(root)/../../bin/npm", version: "12.0.1"),
        instance: ProviderInstance(id: instance, providerID: .npm, executable: "npm", version: "12.0.1"),
        layout: ProviderLayout(roots: [.npmGlobalRoot: root]),
        tools: tools.map { var tool = $0; tool.instanceID = instance; return tool },
        depth: depth,
        scannedAt: date
    )
}

func npmPackage(_ name: String, _ version: String, latest: String? = nil, executables: [String] = []) -> ProviderTool {
    ProviderTool(providerID: .npm, packageName: name, kind: .globalPackage, installedVersions: [version], activeVersion: version, latestVersion: latest, executableNames: executables, isDirect: true)
}

struct StubUpdateSource: UpdateSource {
    var result: UpdateSourceResult?

    func canHandle(_ definition: UpdateSourceDefinition) -> Bool { true }
    func latest(for definition: UpdateSourceDefinition, discovery: DiscoveryResult) async -> UpdateSourceResult? { result }
}

extension EnvironmentSnapshot {
    func issue(_ id: String) -> HealthIssue? { issues.first { $0.id == id } }
    func issues(for tool: ToolID) -> [HealthIssue] { issues.filter { $0.toolID == tool } }
}

extension Tool {
    func installation(_ id: InstallationID) -> ToolInstallation? { installations.first { $0.id == id } }
}

enum MachOHeader {
    static let arm64: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01, 0, 0, 0, 0]
    static let x86_64: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01, 0, 0, 0, 0]
}

// Lets tests write `"path:\(home)/.local/bin/node"` for identifiers.
extension InstallationID: ExpressibleByStringInterpolation {}
extension ProviderInstanceID: ExpressibleByStringInterpolation {}
extension ToolID: ExpressibleByStringInterpolation {}
