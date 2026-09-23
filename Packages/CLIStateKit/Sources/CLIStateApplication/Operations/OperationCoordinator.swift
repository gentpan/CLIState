import CLIStateDomain
import Foundation

/// Serializes mutations that share a scope (§91). Adapted from Infrastructure's `CommandScheduler`.
public protocol MutationLocking: Sendable {
    func withMutationLock<T: Sendable>(scope: String, _ body: @Sendable () async throws -> T) async throws -> T
}

public protocol Trashing: Sendable {
    func moveToTrash(path: String) throws
}

/// Builds self-update plans for native installers from registry metadata (Engine).
public protocol NativeUpdatePlanning: Sendable {
    func selfUpdatePlan(tool: Tool, installation: ToolInstallation) -> OperationPlan?
}

public enum OperationRequest: Hashable, Sendable {
    case update([InstallationID])
    /// `leftovers` are paths from `leftovers(for:)`, moved to the Trash after the provider uninstall.
    case uninstall(InstallationID, leftovers: [String] = [])
    /// Moves leftover files of a tool (installed or not) to the Trash.
    case cleanLeftovers(ToolID, paths: [String])
    case service(ServiceAction, name: String, provider: ProviderID)
    case refreshMetadata(ProviderID)
    case cleanup(candidateID: String)
    case moveToTrash(path: String)
    /// Installs packages through one provider (environment restore, Lane N).
    case install(ProviderID, [InstallRequest])
}

public enum OperationError: Error, Equatable, Sendable {
    /// No scan has completed in this session, so there is no execution environment yet.
    case scanRequired
    case installationNotFound(InstallationID)
    case mixedProviders
    case unsupported(ProviderID)
    case notPermitted(String)
    case candidateNotFound(String)
}

public struct PreparedOperation: Identifiable, Hashable, Sendable {
    public var id: UUID { plan.id }
    public var plan: OperationPlan
    public var checks: [PreflightCheck]

    public init(plan: OperationPlan, checks: [PreflightCheck]) {
        self.plan = plan
        self.checks = checks
    }

    public var isBlocked: Bool { checks.contains(where: \.isBlocking) }
}

public struct OutputLine: Hashable, Sendable {
    public enum Stream: Sendable { case stdout, stderr, system }
    public var stream: Stream
    public var text: String
}

public struct OperationOutcome: Hashable, Sendable {
    public var plan: OperationPlan
    public var status: CommandHistoryEntry.Status
    public var failure: OperationFailure?
    /// Version of each target after the verifying rescan; absent when it was removed.
    /// Also holds dependents the provider upgraded along with the targets.
    public var verifiedVersions: [InstallationID: String]
}

public enum OperationProgress: Sendable {
    case step(index: Int, count: Int, display: String)
    case output(OutputLine)
    case verifying
    case finished(OperationOutcome)
}

/// Runs the write-operation workflow (§46): capability check → plan → preflight →
/// (UI confirmation) → serialized execution with streamed output → rescan →
/// version verification → history.
public actor OperationCoordinator {
    private let scan: ScanCoordinator
    private let runner: any CommandRunning
    private let locks: any MutationLocking
    private let trash: any Trashing
    private let history: any CommandHistoryRepository
    private let fileSystem: any FileSystem
    private let nativePlanner: (any NativeUpdatePlanning)?
    private let leftoverScanner: (any LeftoverScanning)?
    private let clock: @Sendable () -> Date

    public init(
        scan: ScanCoordinator,
        runner: any CommandRunning,
        locks: any MutationLocking,
        trash: any Trashing,
        history: any CommandHistoryRepository,
        fileSystem: any FileSystem,
        nativePlanner: (any NativeUpdatePlanning)? = nil,
        leftoverScanner: (any LeftoverScanning)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scan = scan
        self.runner = runner
        self.locks = locks
        self.trash = trash
        self.history = history
        self.fileSystem = fileSystem
        self.nativePlanner = nativePlanner
        self.leftoverScanner = leftoverScanner
        self.clock = clock
    }

    // MARK: Leftovers

    /// Leftover files of a tool in the current snapshot. Read-only; runs off the actor
    /// because the size walk touches the disk.
    public nonisolated func leftovers(for tool: ToolID) async -> [LeftoverItem] {
        guard let leftoverScanner, let snapshot = await scan.snapshot else { return [] }
        return leftoverScanner.leftovers(for: tool, in: snapshot)
    }

    // MARK: Prepare

    public func prepare(_ request: OperationRequest, trigger: OperationTrigger = .user) async throws -> PreparedOperation {
        guard let discovery = await scan.discoveryResult, let snapshot = await scan.snapshot else { throw OperationError.scanRequired }
        let context = ProviderContext(discovery: discovery, now: clock())

        var plan: OperationPlan
        var checks: [PreflightCheck] = []

        switch request {
        case let .update(ids):
            let installations = try ids.map { try locate($0, in: snapshot) }
            let providerIDs = Set(installations.map(\.installation.ownership.provider))
            guard providerIDs.count == 1, let providerID = providerIDs.first else { throw OperationError.mixedProviders }
            checks += ownershipChecks(installations.map(\.installation), capability: \.canUpdate)

            if providerID == .native {
                guard installations.count == 1, let located = installations.first,
                      let native = nativePlanner?.selfUpdatePlan(tool: located.tool, installation: located.installation)
                else { throw OperationError.unsupported(providerID) }
                plan = native
            } else {
                guard let provider = await scan.provider(providerID) as? any ToolUpdateProvider else { throw OperationError.unsupported(providerID) }
                var packages: [ProviderTool] = []
                for located in installations {
                    guard let package = await scan.providerTool(for: located.installation.id) else { throw OperationError.installationNotFound(located.installation.id) }
                    packages.append(package)
                }
                plan = try provider.updatePlan(for: packages, context: context)
            }
            plan.targets = installations.map { located in
                OperationTarget(
                    toolID: located.tool.id,
                    installationID: located.installation.id,
                    packageName: located.installation.ownership.packageName ?? located.tool.identity.name,
                    displayName: located.tool.identity.displayName,
                    fromVersion: located.installation.version?.value.rawValue,
                    toVersion: located.installation.latest?.value.rawValue
                )
            }
            checks += installations.flatMap { presenceChecks($0.installation) }

        case let .uninstall(id, leftoverPaths):
            let located = try locate(id, in: snapshot)
            checks += ownershipChecks([located.installation], capability: \.canUninstall)
            let providerID = located.installation.ownership.provider
            guard let provider = await scan.provider(providerID) as? any ToolUninstallProvider,
                  let package = await scan.providerTool(for: id)
            else { throw OperationError.unsupported(providerID) }
            plan = try provider.uninstallPlan(for: package, context: context)
            plan.targets = [OperationTarget(toolID: located.tool.id, installationID: id, packageName: package.packageName, displayName: located.tool.identity.displayName, fromVersion: located.installation.version?.value.rawValue)]
            checks += presenceChecks(located.installation)
            if !leftoverPaths.isEmpty {
                // Provider steps first: if the uninstall fails, nothing is moved to the Trash.
                let items = try verifiedLeftovers(leftoverPaths, tool: located.tool.id, snapshot: snapshot)
                plan.steps += items.map { .moveToTrash(path: $0.path) }
                checks.append(Self.userDataCheck(items))
            }

        case let .cleanLeftovers(toolID, paths):
            let items = try verifiedLeftovers(paths, tool: toolID, snapshot: snapshot)
            let tool = snapshot.tool(toolID)
            plan = OperationPlan(
                kind: .cleanup(.leftovers),
                providerID: .standalone,
                targets: [OperationTarget(toolID: toolID, packageName: tool?.identity.name ?? toolID.rawValue, displayName: tool?.identity.displayName ?? toolID.rawValue)],
                steps: items.map { .moveToTrash(path: $0.path) },
                requiresNetwork: false,
                mutationScope: "trash"
            )
            checks.append(Self.userDataCheck(items))

        case let .service(action, name, providerID):
            guard let provider = await scan.provider(providerID) as? any ServiceProvider,
                  let service = await scan.inventory(for: providerID)?.services.first(where: { $0.name == name })
            else { throw OperationError.unsupported(providerID) }
            plan = try provider.servicePlan(action, service: service, context: context)

        case let .refreshMetadata(providerID):
            guard let provider = await scan.provider(providerID) as? any MetadataRefreshProvider else { throw OperationError.unsupported(providerID) }
            plan = try provider.refreshMetadataPlan(context: context)

        case let .cleanup(candidateID):
            guard let candidate = snapshot.cleanupCandidates.first(where: { $0.id == candidateID }), let candidatePlan = candidate.plan else {
                throw OperationError.candidateNotFound(candidateID)
            }
            plan = candidatePlan

        case let .install(providerID, requests):
            guard let provider = await scan.provider(providerID) as? any ToolInstallProvider else { throw OperationError.unsupported(providerID) }
            plan = try provider.installPlan(for: requests, context: context)
            checks.append(Self.packageNameCheck(requests))

        case let .moveToTrash(path):
            guard Self.trashablePaths(in: snapshot).contains(path) else { throw OperationError.notPermitted(path) }
            plan = OperationPlan(kind: .moveToTrash, providerID: .standalone, targets: [OperationTarget(packageName: path, displayName: (path as NSString).lastPathComponent)], steps: [.moveToTrash(path: path)], requiresNetwork: false, mutationScope: "trash")
        }

        plan.trigger = trigger
        checks += await genericChecks(for: plan, context: context)
        if let provider = await scan.provider(plan.providerID) as? any OperationPreflightProvider {
            checks += await provider.preflight(for: plan, context: context)
        }
        return PreparedOperation(plan: plan, checks: Self.deduplicated(checks))
    }

    /// Update All (§143): one prepared operation per provider, in stable order.
    public func prepareUpdateAll(_ ids: [InstallationID], trigger: OperationTrigger = .user) async throws -> [PreparedOperation] {
        guard let snapshot = await scan.snapshot else { throw OperationError.scanRequired }
        var groups: [ProviderID: [InstallationID]] = [:]
        for id in ids {
            let located = try locate(id, in: snapshot)
            groups[located.installation.ownership.provider, default: []].append(id)
        }
        var prepared: [PreparedOperation] = []
        for providerID in groups.keys.sorted() {
            let members = groups[providerID] ?? []
            if providerID == .native {
                for id in members { prepared.append(try await prepare(.update([id]), trigger: trigger)) }
            } else {
                prepared.append(try await prepare(.update(members), trigger: trigger))
            }
        }
        return prepared
    }

    // MARK: Execute

    public func execute(_ prepared: PreparedOperation) -> AsyncStream<OperationProgress> {
        AsyncStream(bufferingPolicy: .bufferingNewest(4096)) { continuation in
            let task = Task {
                let outcome = await self.run(prepared) { continuation.yield($0) }
                continuation.yield(.finished(outcome))
                continuation.finish()
            }
            // Mutations are not cancelled when the observer goes away (§90).
            continuation.onTermination = { _ in _ = task }
        }
    }

    private func run(_ prepared: PreparedOperation, progress: @escaping @Sendable (OperationProgress) -> Void) async -> OperationOutcome {
        let plan = prepared.plan
        var entry = CommandHistoryEntry(
            id: plan.id,
            planKind: plan.kind,
            trigger: plan.trigger,
            providerID: plan.providerID,
            commands: plan.steps.map(\.displayString),
            targets: plan.targets,
            status: .running,
            startedAt: clock()
        )

        if prepared.isBlocked {
            entry.status = .failed
            entry.finishedAt = clock()
            try? await history.upsert(entry)
            return OperationOutcome(plan: plan, status: .failed, failure: OperationFailure(reason: .preflightBlocked), verifiedVersions: [:])
        }
        guard let execution = await scan.discoveryResult?.session.execution else {
            return OperationOutcome(plan: plan, status: .failed, failure: OperationFailure(reason: .unknown), verifiedVersions: [:])
        }
        try? await history.upsert(entry)

        // Defense in depth: a plan built elsewhere can only trash what prepare would allow.
        if let refused = await refusedTrashPath(in: plan) {
            entry.status = .failed
            entry.finishedAt = clock()
            try? await history.upsert(entry)
            return OperationOutcome(plan: plan, status: .failed, failure: OperationFailure(reason: .preflightBlocked, command: OperationStep.moveToTrash(path: refused).displayString), verifiedVersions: [:])
        }

        let runner = self.runner
        let trash = self.trash
        let failure: OperationFailure?
        do {
            failure = try await locks.withMutationLock(scope: plan.mutationScope) {
                for (index, step) in plan.steps.enumerated() {
                    progress(.step(index: index + 1, count: plan.steps.count, display: step.displayString))
                    switch step {
                    case let .moveToTrash(path):
                        do {
                            try trash.moveToTrash(path: path)
                            progress(.output(OutputLine(stream: .system, text: path)))
                        } catch {
                            return OperationFailure(reason: .permissionDenied, command: step.displayString)
                        }
                    case let .command(command):
                        var transcript = TranscriptTail()
                        var result: CommandResult?
                        for try await event in runner.stream(command, environment: execution) {
                            switch event {
                            case let .stdout(line):
                                transcript.append(line)
                                progress(.output(OutputLine(stream: .stdout, text: line)))
                            case let .stderr(line):
                                transcript.append(line)
                                progress(.output(OutputLine(stream: .stderr, text: line)))
                            case let .finished(finished):
                                result = finished
                            case .started:
                                break
                            }
                        }
                        guard let result, result.succeeded else {
                            return OperationFailure(reason: Self.classify(transcript.text), command: command.displayString, exitCode: result?.exitCode)
                        }
                    }
                }
                return nil
            }
        } catch {
            failure = OperationFailure(reason: .unknown)
        }

        // Never trust the exit code alone: rescan and compare (§26).
        progress(.verifying)
        let refreshed = await scan.scan(depth: .fast)
        var verified: [InstallationID: String] = [:]
        var status: CommandHistoryEntry.Status = failure == nil ? .succeeded : .failed
        var finalFailure = failure
        if refreshed == nil, failure == nil {
            switch plan.kind {
            case .install, .update, .selfUpdate, .uninstall: status = .unverified
            default: break
            }
        }

        if let refreshed, plan.kind == .install, failure == nil {
            // Installed packages have no installation ID before the rescan.
            for target in plan.targets {
                guard let installation = Self.installed(target, provider: plan.providerID, in: refreshed) else {
                    status = .unverified
                    continue
                }
                if let version = installation.version?.value.rawValue { verified[installation.id] = version }
            }
        }
        if let refreshed {
            // Dependents are recorded but never decide the status: only the requested
            // targets must change for the operation to count as verified.
            let targetIDs = Set(plan.targets.compactMap(\.installationID))
            for (id, version) in Self.dependentVersions(checks: prepared.checks, plan: plan, in: refreshed) where !targetIDs.contains(id) {
                verified[id] = version
            }
            for target in plan.targets {
                guard let id = target.installationID else { continue }
                let installation = refreshed.tools.lazy.flatMap(\.installations).first { $0.id == id }
                if let version = installation?.version?.value.rawValue { verified[id] = version }
                guard failure == nil else { continue }
                switch plan.kind {
                case .update, .selfUpdate:
                    if let version = installation?.version?.value.rawValue {
                        if version == target.fromVersion {
                            status = .unverified
                            finalFailure = OperationFailure(reason: .versionUnchanged, command: plan.steps.last?.displayString)
                        }
                    } else {
                        status = .unverified
                    }
                case .uninstall:
                    if installation != nil { status = .unverified }
                default:
                    break
                }
            }
        }

        entry.status = status
        entry.exitCode = finalFailure?.exitCode ?? (failure == nil ? 0 : nil)
        entry.verifiedVersions = Dictionary(uniqueKeysWithValues: verified.map { ($0.key.rawValue, $0.value) })
        entry.finishedAt = clock()
        try? await history.upsert(entry)
        return OperationOutcome(plan: plan, status: status, failure: finalFailure, verifiedVersions: verified)
    }

    /// Installed dependents the preflight said would be upgraded too (`brew upgrade`
    /// upgrades dependents of what it upgrades), as the verifying rescan observed them.
    static func dependentVersions(checks: [PreflightCheck], plan: OperationPlan, in snapshot: EnvironmentSnapshot) -> [InstallationID: String] {
        guard plan.kind == .update else { return [:] }
        let names = Set(checks.flatMap(\.items).filter { $0.change == .upgradeDependent }.map(\.name))
        guard !names.isEmpty else { return [:] }
        // Tap formulae can be listed by full name (`owner/tap/name`).
        let shortNames = Set(names.map { $0.split(separator: "/").last.map(String.init) ?? $0 })
        var versions: [InstallationID: String] = [:]
        for tool in snapshot.tools {
            for installation in tool.installations where installation.ownership.provider == plan.providerID {
                guard let package = installation.ownership.packageName,
                      names.contains(package) || shortNames.contains(package),
                      let version = installation.version?.value.rawValue
                else { continue }
                versions[installation.id] = version
            }
        }
        return versions
    }

    // MARK: Checks

    /// Re-runs the scanner and keeps only paths it returns, in request order.
    private func verifiedLeftovers(_ paths: [String], tool: ToolID, snapshot: EnvironmentSnapshot) throws -> [LeftoverItem] {
        guard let leftoverScanner else { throw OperationError.unsupported(.standalone) }
        var seen = Set<String>()
        let requested = paths.filter { seen.insert($0).inserted }
        guard !requested.isEmpty else { throw OperationError.notPermitted("") }
        let found = Dictionary(leftoverScanner.leftovers(for: tool, in: snapshot).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return try requested.map { path in
            guard let item = found[path] else { throw OperationError.notPermitted(path) }
            return item
        }
    }

    private static func packageNameCheck(_ requests: [InstallRequest]) -> PreflightCheck {
        let names = requests.map(\.packageName) + requests.compactMap(\.tap)
        let invalid = names.filter { !EnvironmentRestore.isValidPackageName($0) }
        return PreflightCheck(kind: .packageNameValid, outcome: invalid.isEmpty ? .passed : .failed, detail: invalid.isEmpty ? nil : invalid.joined(separator: "\n"))
    }

    /// The package a finished install should have produced: same provider and
    /// name (Homebrew without the tap), or the same registry tool from that provider
    /// (`postgresql` resolving to `postgresql@17`).
    static func installed(_ target: OperationTarget, provider: ProviderID, in snapshot: EnvironmentSnapshot) -> ToolInstallation? {
        let name = provider == .homebrew ? (target.packageName as NSString).lastPathComponent : target.packageName
        let owned = snapshot.tools.lazy.flatMap(\.installations).filter { $0.ownership.provider == provider }
        if let exact = owned.first(where: { $0.ownership.packageName == name }) { return exact }
        guard let toolID = target.toolID else { return nil }
        return snapshot.tool(toolID)?.installations.first { $0.ownership.provider == provider }
    }

    private static func userDataCheck(_ items: [LeftoverItem]) -> PreflightCheck {
        let userData = items.filter(\.containsUserData)
        return PreflightCheck(
            kind: .userData,
            outcome: userData.isEmpty ? .passed : .warning,
            detail: userData.isEmpty ? nil : userData.map(\.path).joined(separator: "\n")
        )
    }

    private func refusedTrashPath(in plan: OperationPlan) async -> String? {
        let paths = plan.steps.compactMap { step -> String? in
            if case let .moveToTrash(path) = step { return path }
            return nil
        }
        guard !paths.isEmpty else { return nil }
        guard let snapshot = await scan.snapshot else { return paths.first }
        var leftovers: [LeftoverItem] = []
        if let leftoverScanner {
            for tool in Set(plan.targets.compactMap(\.toolID)) {
                leftovers += leftoverScanner.leftovers(for: tool, in: snapshot)
            }
        }
        let allowed = Self.trashablePaths(in: snapshot, leftovers: leftovers)
        return paths.first { !allowed.contains($0) }
    }

    private func locate(_ id: InstallationID, in snapshot: EnvironmentSnapshot) throws -> (tool: Tool, installation: ToolInstallation) {
        for tool in snapshot.tools {
            if let installation = tool.installations.first(where: { $0.id == id }) { return (tool, installation) }
        }
        throw OperationError.installationNotFound(id)
    }

    private func ownershipChecks(_ installations: [ToolInstallation], capability: KeyPath<ToolCapabilities, Bool>) -> [PreflightCheck] {
        let systemManaged = installations.filter(\.isSystemManaged)
        if !systemManaged.isEmpty {
            return [PreflightCheck(kind: .systemManaged, outcome: .failed, detail: systemManaged.map(\.id.rawValue).joined(separator: ", "))]
        }
        let unconfirmed = installations.filter { !$0.ownership.permitsMutation || !$0.capabilities[keyPath: capability] }
        return [PreflightCheck(
            kind: .ownershipConfirmed,
            outcome: unconfirmed.isEmpty ? .passed : .failed,
            detail: unconfirmed.isEmpty ? nil : unconfirmed.map(\.id.rawValue).joined(separator: ", ")
        )]
    }

    private func presenceChecks(_ installation: ToolInstallation) -> [PreflightCheck] {
        let paths = [installation.installPrefix].compactMap { $0 } + installation.executables.map(\.path)
        let present = paths.isEmpty || paths.contains { fileSystem.exists(atPath: $0) }
        var checks = [PreflightCheck(kind: .installationPresent, outcome: present ? .passed : .failed, detail: paths.first)]
        if let prefix = installation.installPrefix {
            // Write access is needed on the directory that holds the install, not the install itself.
            let parent = (prefix as NSString).deletingLastPathComponent
            let writable = fileSystem.isWritable(atPath: parent)
            checks.append(PreflightCheck(kind: .writableLocation, outcome: writable ? .passed : .failed, detail: parent))
        }
        return checks
    }

    private func genericChecks(for plan: OperationPlan, context: ProviderContext) async -> [PreflightCheck] {
        var checks: [PreflightCheck] = []
        let executables = Set(plan.commands.map(\.executable))
        for executable in executables.sorted() {
            let available = fileSystem.isExecutableFile(atPath: executable)
            checks.append(PreflightCheck(kind: .providerAvailable, outcome: available ? .passed : .failed, detail: executable))
            let name = (executable as NSString).lastPathComponent
            if available, let resolved = context.resolveExecutable(name), resolved != executable {
                checks.append(PreflightCheck(kind: .providerUnchanged, outcome: .warning, detail: "\(executable) → \(resolved)"))
            }
        }
        if plan.requiresNetwork {
            checks.append(PreflightCheck(kind: .networkRequired, outcome: .info))
        }
        return checks
    }

    /// Keeps the most severe check per kind+detail so repeated generic checks don't clutter the sheet.
    static func deduplicated(_ checks: [PreflightCheck]) -> [PreflightCheck] {
        var seen: [String: Int] = [:]
        var result: [PreflightCheck] = []
        let rank: [PreflightOutcome: Int] = [.info: 0, .passed: 1, .warning: 2, .failed: 3]
        for check in checks {
            let key = "\(check.kind.rawValue)|\(check.detail ?? "")"
            if let index = seen[key] {
                if rank[check.outcome, default: 0] > rank[result[index].outcome, default: 0] { result[index] = check }
            } else {
                seen[key] = result.count
                result.append(check)
            }
        }
        return result
    }

    /// The end of a command's output, enough to classify a failure. Output itself is
    /// streamed to the UI and never stored (§147); an upgrade printing megabytes
    /// shouldn't be buffered twice.
    struct TranscriptTail {
        static let limit = 64 * 1024
        private(set) var text = ""

        mutating func append(_ line: String) {
            text += line
            text += "\n"
            // Trim in chunks so long outputs don't copy the buffer on every line.
            if text.utf8.count > Self.limit * 2 {
                text = String(decoding: text.utf8.suffix(Self.limit), as: UTF8.self)
            }
        }
    }

    static func classify(_ transcript: String) -> OperationFailure.Reason {
        let text = transcript.lowercased()
        if text.contains("permission denied") || text.contains("eacces") || text.contains("operation not permitted") { return .permissionDenied }
        if text.contains("could not resolve host") || text.contains("enotfound") || text.contains("network is unreachable") || text.contains("timed out") { return .networkUnavailable }
        if text.contains("another active homebrew") || text.contains("has already locked") { return .providerLocked }
        return .commandFailed
    }

    /// Everything a `.moveToTrash` step may touch: broken links, executables of
    /// unowned installations, and leftovers the scanner just returned.
    static func trashablePaths(in snapshot: EnvironmentSnapshot, leftovers: [LeftoverItem] = []) -> Set<String> {
        var paths = Set(snapshot.brokenSymlinks.map(\.path)).union(leftovers.map(\.path))
        for tool in snapshot.tools {
            for installation in tool.installations where installation.capabilities.canMoveToTrash && !installation.isSystemManaged {
                paths.formUnion(installation.executables.map(\.path))
            }
        }
        return paths
    }
}
