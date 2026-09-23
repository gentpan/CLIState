import CLIStateDomain
import Foundation

/// Simulates the engine against `SampleSnapshot`: builds plans, fakes
/// preflight checks and streams plausible output. Runs no processes.
@MainActor
final class PreviewActions: AppActions {
    enum PreviewError: LocalizedError {
        case notFound

        var errorDescription: String? {
            String(localized: "This item is no longer in the latest scan. Refresh, then try again.")
        }
    }

    /// Internal so feature extensions (environment restore) can simulate their operations.
    var snapshot: EnvironmentSnapshot
    private var history: [CommandHistoryEntry]
    private var preferences: UpdatePreferences
    private var leftoverStore: [ToolID: [LeftoverItem]]
    /// Simulated latency multiplier; previews use 0 to render instantly.
    let pace: Double

    init(snapshot: EnvironmentSnapshot = SampleSnapshot.make(), pace: Double = 1) {
        self.snapshot = snapshot
        self.history = SampleSnapshot.history()
        self.preferences = UpdatePreferences(
            providerPolicies: [.native: .automatic],
            skippedVersions: [:]
        )
        self.leftoverStore = SampleSnapshot.leftovers()
        self.pace = pace
    }

    // MARK: Scans

    func loadCachedSnapshot() async -> EnvironmentSnapshot? {
        nil
    }

    func runBackgroundCheck(preferences: UpdatePreferences, allowAutomaticInstalls: Bool) async -> BackgroundCheckResult? {
        nil
    }

    func refreshCleanupCandidates() async -> EnvironmentSnapshot? {
        nil
    }

    func refresh() async throws -> EnvironmentSnapshot {
        try await pause(milliseconds: 500)
        snapshot.capturedAt = .now
        snapshot.depth = .fast
        return snapshot
    }

    func forceCheckForUpdates() async throws -> EnvironmentSnapshot {
        try await checkForUpdates()
    }

    func checkForUpdates() async throws -> EnvironmentSnapshot {
        try await pause(milliseconds: 1400)
        let now = Date.now
        snapshot.capturedAt = now
        snapshot.depth = .deep
        snapshot.latestCheckedAt = now
        for index in snapshot.providers.indices {
            snapshot.providers[index].latestCheckedAt = now
        }
        return snapshot
    }

    func exportDiagnostics(to url: URL) async throws {
        try Data("CLI State sample data — diagnostics are only exported from real scans.\n".utf8).write(to: url)
    }

    func loadHistory() async throws -> [CommandHistoryEntry] {
        history.sorted { $0.startedAt > $1.startedAt }
    }

    func loadPreferences() async throws -> UpdatePreferences {
        preferences
    }

    // MARK: Plans

    func planUpdate(_ installations: [InstallationRef]) async throws -> PreparedOperation {
        try await pause(milliseconds: 250)
        let resolved = try installations.map { ref -> (Tool, ToolInstallation) in
            guard let tool = snapshot.tool(ref.toolID), let installation = tool.installation(ref.installationID) else { throw PreviewError.notFound }
            return (tool, installation)
        }
        let byProvider = Dictionary(grouping: resolved) { $0.1.ownership.provider }
        let order: [ProviderID] = [.homebrew, .npm, .uv, .native]
        let providers = byProvider.keys.sorted { (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count) }

        var plans: [PreparedPlan] = []
        for provider in providers {
            let items = byProvider[provider] ?? []
            let targets = items.map { tool, installation in
                OperationTarget(toolID: tool.id, installationID: installation.id, packageName: installation.ownership.packageName ?? tool.identity.name, displayName: tool.identity.displayName, fromVersion: installation.version?.value.rawValue, toVersion: installation.latest?.value.rawValue)
            }
            switch provider {
            case .native:
                // Native installers update one tool at a time.
                for (tool, installation) in items {
                    let target = targets.first { $0.installationID == installation.id }.map { [$0] } ?? []
                    let executable = installation.primaryExecutable?.path ?? tool.identity.name
                    let arguments = tool.id == "uv" ? ["self", "update"] : ["update"]
                    let plan = OperationPlan(kind: .selfUpdate, providerID: .native, targets: target, commands: [Command(executable: executable, arguments: arguments)], requiresNetwork: true, mutationScope: "native:\(tool.id)")
                    plans.append(PreparedPlan(plan: plan, checks: genericChecks(provider: .native, detail: executable)))
                }
            default:
                let names = targets.map(\.packageName)
                let command: Command
                switch provider {
                case .homebrew:
                    command = Command(executable: SampleSnapshot.brew, arguments: ["upgrade"] + names, environmentOverrides: SampleSnapshot.homebrewEnv)
                case .npm:
                    command = Command(executable: "/opt/homebrew/bin/npm", arguments: ["install", "--global"] + targets.map { "\($0.packageName)@\($0.toVersion ?? "latest")" })
                case .uv:
                    command = Command(executable: "\(SampleSnapshot.home)/.local/bin/uv", arguments: ["tool", "upgrade"] + names)
                default:
                    command = Command(executable: provider.rawValue, arguments: ["upgrade"] + names)
                }
                let plan = OperationPlan(kind: .update, providerID: provider, targets: targets, commands: [command], requiresNetwork: true)
                let checks = (provider == .homebrew && names == ["php"]) ? SampleSnapshot.phpUpdatePreflight() : genericChecks(provider: provider, detail: command.executable)
                plans.append(PreparedPlan(plan: plan, checks: checks))
            }
        }
        return PreparedOperation(plans: plans)
    }

    func planUninstall(_ ref: InstallationRef, leftovers: [String]) async throws -> PreparedOperation {
        try await pause(milliseconds: 250)
        guard let tool = snapshot.tool(ref.toolID), let installation = tool.installation(ref.installationID) else { throw PreviewError.notFound }
        let provider = installation.ownership.provider
        let package = installation.ownership.packageName ?? tool.identity.name
        let command: Command = switch provider {
        case .homebrew: Command(executable: SampleSnapshot.brew, arguments: ["uninstall", package], environmentOverrides: SampleSnapshot.homebrewEnv)
        case .npm: Command(executable: "/opt/homebrew/bin/npm", arguments: ["uninstall", "--global", package])
        case .uv: Command(executable: "\(SampleSnapshot.home)/.local/bin/uv", arguments: ["tool", "uninstall", package])
        default: Command(executable: provider.rawValue, arguments: ["uninstall", package])
        }
        let target = OperationTarget(toolID: tool.id, installationID: installation.id, packageName: package, displayName: installation.id == tool.primaryInstallation?.id ? tool.identity.displayName : package, fromVersion: installation.version?.value.rawValue)
        var checks = [
            PreflightCheck(kind: .providerAvailable, outcome: .passed, detail: command.executable),
            PreflightCheck(kind: .ownershipConfirmed, outcome: installation.ownership.permitsMutation ? .passed : .failed, detail: installation.id.rawValue),
            PreflightCheck(kind: .systemManaged, outcome: installation.isSystemManaged ? .failed : .passed),
        ]
        if !installation.dependents.isEmpty {
            checks.append(PreflightCheck(kind: .reverseDependencies, outcome: .warning, detail: installation.dependents.joined(separator: ", "),
                                         items: installation.dependents.map { PreflightItem(name: $0, change: .dependent) }))
        }
        var plan = OperationPlan(kind: .uninstall, providerID: provider, targets: [target], commands: [command], requiresNetwork: false)
        if !leftovers.isEmpty {
            let items = try verifiedLeftovers(leftovers, tool: tool.id)
            plan.steps += items.map { .moveToTrash(path: $0.path) }
            checks.append(userDataCheck(items))
        }
        return PreparedOperation(plans: [PreparedPlan(plan: plan, checks: checks)])
    }

    func planCleanLeftovers(tool toolID: ToolID, paths: [String]) async throws -> PreparedOperation {
        try await pause(milliseconds: 200)
        let items = try verifiedLeftovers(paths, tool: toolID)
        let tool = snapshot.tool(toolID)
        let target = OperationTarget(toolID: toolID, packageName: tool?.identity.name ?? toolID.rawValue, displayName: tool?.identity.displayName ?? toolID.rawValue)
        let plan = OperationPlan(kind: .cleanup(.leftovers), providerID: .standalone, targets: [target], steps: items.map { .moveToTrash(path: $0.path) }, requiresNetwork: false, mutationScope: "trash")
        return PreparedOperation(plans: [PreparedPlan(plan: plan, checks: [userDataCheck(items)])])
    }

    func leftovers(for tool: ToolID) async -> [LeftoverItem] {
        try? await pause(milliseconds: 400)
        return leftoverStore[tool] ?? []
    }

    /// Mirrors the coordinator: only paths the scan returned are accepted.
    private func verifiedLeftovers(_ paths: [String], tool: ToolID) throws -> [LeftoverItem] {
        let found = leftoverStore[tool] ?? []
        return try paths.map { path in
            guard let item = found.first(where: { $0.path == path }) else { throw PreviewError.notFound }
            return item
        }
    }

    private func userDataCheck(_ items: [LeftoverItem]) -> PreflightCheck {
        let userData = items.filter(\.containsUserData)
        return PreflightCheck(kind: .userData, outcome: userData.isEmpty ? .passed : .warning, detail: userData.isEmpty ? nil : userData.map(\.path).joined(separator: "\n"))
    }

    func planService(_ action: ServiceAction, service: ToolService) async throws -> PreparedOperation {
        try await pause(milliseconds: 150)
        let tool = service.toolID.flatMap(snapshot.tool)
        let target = OperationTarget(toolID: service.toolID, installationID: service.installationID, packageName: service.name, displayName: tool?.identity.displayName ?? service.name)
        let command = Command(executable: SampleSnapshot.brew, arguments: ["services", action.rawValue, service.name], environmentOverrides: SampleSnapshot.homebrewEnv)
        let plan = OperationPlan(kind: .service(action), providerID: service.providerID, targets: [target], commands: [command], requiresNetwork: false)
        let checks = [
            PreflightCheck(kind: .providerAvailable, outcome: .passed, detail: SampleSnapshot.brew),
            PreflightCheck(kind: .installationPresent, outcome: .passed, detail: service.plistPath ?? service.name),
        ]
        return PreparedOperation(plans: [PreparedPlan(plan: plan, checks: checks)])
    }

    func planCleanup(_ candidate: CleanupCandidate) async throws -> PreparedOperation {
        try await pause(milliseconds: 300)
        guard let plan = candidate.plan else { throw PreviewError.notFound }
        var checks: [PreflightCheck] = []
        if candidate.providerID != nil {
            checks.append(PreflightCheck(kind: .providerAvailable, outcome: .passed, detail: plan.commands.first?.executable))
        }
        switch candidate.kind {
        case .brokenSymlink:
            checks.append(PreflightCheck(kind: .installationPresent, outcome: .passed, detail: String(candidate.paths.count)))
            checks.append(PreflightCheck(kind: .ownershipConfirmed, outcome: .info))
        default:
            let dryRun = plan.commands.first.map { $0.displayString + " --dry-run" }
            checks.append(PreflightCheck(kind: .dryRun, outcome: candidate.risk == .medium ? .warning : .passed, detail: dryRun, items: candidate.items))
        }
        return PreparedOperation(plans: [PreparedPlan(plan: plan, checks: checks)])
    }

    func planMoveToTrash(paths: [String], toolID: ToolID?) async throws -> PreparedOperation {
        try await pause(milliseconds: 150)
        let tool = toolID.flatMap(snapshot.tool)
        let targets = paths.map { OperationTarget(toolID: toolID, packageName: $0, displayName: tool?.identity.displayName ?? ($0 as NSString).lastPathComponent) }
        let plan = OperationPlan(kind: .moveToTrash, providerID: .standalone, targets: targets, steps: paths.map { .moveToTrash(path: $0) }, requiresNetwork: false, mutationScope: "trash")
        let checks = [
            PreflightCheck(kind: .installationPresent, outcome: .passed, detail: paths.joined(separator: "\n")),
            PreflightCheck(kind: .ownershipConfirmed, outcome: .info),
            PreflightCheck(kind: .writableLocation, outcome: .passed),
        ]
        return PreparedOperation(plans: [PreparedPlan(plan: plan, checks: checks)])
    }

    func planRefreshMetadata(provider: ProviderID) async throws -> PreparedOperation {
        try await pause(milliseconds: 150)
        let command = Command(executable: SampleSnapshot.brew, arguments: ["update"])
        let plan = OperationPlan(kind: .refreshMetadata, providerID: provider, targets: [OperationTarget(packageName: provider.rawValue, displayName: provider.displayName)], commands: [command], requiresNetwork: true)
        let checks = [
            PreflightCheck(kind: .providerAvailable, outcome: .passed, detail: SampleSnapshot.brew),
            PreflightCheck(kind: .networkRequired, outcome: .info),
        ]
        return PreparedOperation(plans: [PreparedPlan(plan: plan, checks: checks)])
    }

    // MARK: Running

    func run(_ prepared: PreparedPlan) -> AsyncThrowingStream<OperationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let startedAt = Date.now
                    let script = self.script(for: prepared.plan)
                    for step in prepared.plan.steps {
                        continuation.yield(.stepStarted(step))
                        try await self.pause(milliseconds: 200)
                    }
                    for (text, isError) in script.lines {
                        try await self.pause(milliseconds: 160)
                        continuation.yield(isError ? .errorOutput(text) : .output(text))
                    }
                    try await self.pause(milliseconds: 300)
                    self.apply(prepared.plan, outcome: script.outcome)
                    self.record(prepared.plan, outcome: script.outcome, startedAt: startedAt)
                    continuation.yield(.finished(script.outcome))
                    continuation.finish()
                } catch {
                    continuation.yield(.finished(.cancelled))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Preferences

    func setPolicy(_ policy: AutoUpdatePolicy?, for tool: ToolID) async throws -> UpdatePreferences {
        preferences.toolPolicies[tool] = policy
        return preferences
    }

    func skipVersion(_ version: String?, for installation: InstallationID) async throws -> UpdatePreferences {
        preferences.skippedVersions[installation] = version
        return preferences
    }

    func savePreferences(_ preferences: UpdatePreferences) async throws {
        self.preferences = preferences
    }

    // MARK: Simulation

    private struct Script {
        /// Output line and whether it went to stderr.
        var lines: [(String, Bool)]
        var outcome: OperationOutcome
    }

    private func script(for plan: OperationPlan) -> Script {
        let names = plan.targets.map(\.packageName)
        switch plan.kind {
        case .update where plan.providerID == .homebrew:
            if names.contains("ffmpeg") {
                return Script(lines: [
                    ("==> Fetching downloads for: \(names.joined(separator: ", "))", false),
                    ("==> Upgrading ffmpeg 8.1.2_1 -> 9.0.1", false),
                    ("Error: ffmpeg: Failed to download resource \"ffmpeg--9.0.1\"", true),
                    ("curl: (56) Recv failure: Connection reset by peer", true),
                ], outcome: .failed(OperationFailure(reason: .commandFailed, command: "brew upgrade \(names.joined(separator: " "))", exitCode: 1)))
            }
            var lines: [(String, Bool)] = [("==> Fetching downloads for: \(names.joined(separator: ", "))", false)]
            if names.contains("php") {
                lines += [
                    ("==> Upgrading 9 dependencies of php: apr-util, libssh2, curl, freetds, fontconfig, aom, dav1d, libpq, openldap", false),
                    ("==> Installing php dependency: libpsl", false),
                    ("==> Pouring libpsl--0.23.3.arm64_tahoe.bottle.tar.gz", false),
                ]
            }
            for target in plan.targets {
                lines.append(("==> Upgrading \(target.packageName) \(target.fromVersion ?? "") -> \(target.toVersion ?? "")", false))
                lines.append(("==> Pouring \(target.packageName)--\(target.toVersion ?? "").arm64_tahoe.bottle.tar.gz", false))
                lines.append(("/opt/homebrew/Cellar/\(target.packageName)/\(target.toVersion ?? ""): 412 files, 64.2MB", false))
            }
            if names.contains("php") {
                lines.append(("==> Upgrading dependent composer 2.9.8 -> 2.10.3", false))
            }
            return Script(lines: lines, outcome: .succeeded(verifiedVersions: verified(plan)))
        case .update:
            let lines = plan.targets.map { ("Updated \($0.packageName) v\($0.fromVersion ?? "") -> v\($0.toVersion ?? "")", false) }
            return Script(lines: [("Resolving packages…", false)] + lines, outcome: .succeeded(verifiedVersions: verified(plan)))
        case .selfUpdate:
            let target = plan.targets.first
            return Script(lines: [
                ("Current version: \(target?.fromVersion ?? "")", false),
                ("Checking for updates…", false),
                ("Successfully updated from \(target?.fromVersion ?? "") to version \(target?.toVersion ?? "")", false),
            ], outcome: .succeeded(verifiedVersions: verified(plan)))
        case .uninstall:
            return Script(lines: [("Uninstalling \(names.joined(separator: " "))… (128 files, 42.7MB)", false)] + trashLines(plan), outcome: .succeeded(verifiedVersions: [:]))
        case let .service(action):
            let verb = action == .stop ? "stopped" : "started"
            return Script(lines: [("==> Successfully \(verb) `\(names.first ?? "")` (label: homebrew.mxcl.\(names.first ?? ""))", false)], outcome: .succeeded(verifiedVersions: [:]))
        case .refreshMetadata:
            return Script(lines: [
                ("==> Updating Homebrew...", false),
                ("==> Updated 2 taps (homebrew/core and homebrew/cask).", false),
                ("==> New Formulae: 14, Outdated Formulae: 11", false),
            ], outcome: .succeeded(verifiedVersions: [:]))
        case .cleanup(.brokenSymlink), .cleanup(.leftovers), .moveToTrash:
            return Script(lines: trashLines(plan), outcome: .succeeded(verifiedVersions: [:]))
        case .install:
            return Script(lines: installLines(plan), outcome: .succeeded(verifiedVersions: [:]))
        case .cleanup:
            return Script(lines: [
                ("Removing: \(SampleSnapshot.home)/Library/Caches/Homebrew/downloads… (18 files, 1.1GB)", false),
                ("==> This operation has freed approximately 1.2GB of disk space.", false),
            ], outcome: .succeeded(verifiedVersions: [:]))
        }
    }

    private func trashLines(_ plan: OperationPlan) -> [(String, Bool)] {
        plan.steps.compactMap { step -> (String, Bool)? in
            if case let .moveToTrash(path) = step { return ("Moved \(path) to the Trash", false) }
            return nil
        }
    }

    private func verified(_ plan: OperationPlan) -> [String: String] {
        Dictionary(plan.targets.compactMap { target in target.toVersion.map { (target.packageName, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// Mirrors what a rescan would observe after the operation.
    private func apply(_ plan: OperationPlan, outcome: OperationOutcome) {
        guard case .succeeded = outcome else { return }
        let now = Date.now
        let trashed = Set(plan.steps.compactMap { step -> String? in
            if case let .moveToTrash(path) = step { return path }
            return nil
        })
        for tool in leftoverStore.keys {
            leftoverStore[tool]?.removeAll { trashed.contains($0.path) }
        }
        switch plan.kind {
        case .update, .selfUpdate:
            for target in plan.targets {
                mutateInstallation(target) { installation in
                    guard let latest = installation.latest else { return }
                    installation.version = ObservedValue(latest.value, source: latest.source, confidence: .confirmed, observedAt: now)
                }
            }
            for index in snapshot.tools.indices where snapshot.tools[index].health.status == .updateAvailable && !snapshot.tools[index].hasUpdate {
                snapshot.tools[index].health.status = .healthy
            }
        case .uninstall:
            for target in plan.targets {
                guard let toolIndex = snapshot.tools.firstIndex(where: { $0.id == target.toolID }) else { continue }
                snapshot.tools[toolIndex].installations.removeAll { $0.id == target.installationID }
                if snapshot.tools[toolIndex].installations.isEmpty { snapshot.tools.remove(at: toolIndex) }
            }
        case let .service(action):
            for index in snapshot.services.indices where plan.targets.contains(where: { $0.packageName == snapshot.services[index].name }) {
                let running = action != .stop
                snapshot.services[index].status = running ? .running : .stopped
                let service = snapshot.services[index]
                if let toolIndex = snapshot.tools.firstIndex(where: { $0.id == service.toolID }) {
                    snapshot.tools[toolIndex].service = service
                    for installationIndex in snapshot.tools[toolIndex].installations.indices where snapshot.tools[toolIndex].installations[installationIndex].id == service.installationID {
                        snapshot.tools[toolIndex].installations[installationIndex].capabilities.canStart = !running
                        snapshot.tools[toolIndex].installations[installationIndex].capabilities.canStop = running
                        snapshot.tools[toolIndex].installations[installationIndex].capabilities.canRestart = running
                    }
                }
            }
        case .refreshMetadata:
            if let index = snapshot.providers.firstIndex(where: { $0.providerID == plan.providerID }) {
                snapshot.providers[index].latestCheckedAt = now
            }
        case .install:
            applyInstall(plan, at: now)
        case let .cleanup(kind):
            snapshot.cleanupCandidates.removeAll { $0.plan?.id == plan.id }
            if kind == .brokenSymlink {
                snapshot.brokenSymlinks.removeAll()
                snapshot.issues.removeAll { $0.type == .brokenSymlink }
            }
        case .moveToTrash:
            let paths = Set(plan.steps.compactMap { step -> String? in
                if case let .moveToTrash(path) = step { return path }
                return nil
            })
            for toolIndex in snapshot.tools.indices.reversed() {
                snapshot.tools[toolIndex].installations.removeAll { installation in
                    installation.executables.contains { paths.contains($0.path) }
                }
                if snapshot.tools[toolIndex].installations.isEmpty {
                    snapshot.tools.remove(at: toolIndex)
                } else if let activeID = snapshot.tools[toolIndex].activeInstallationID,
                          snapshot.tools[toolIndex].installation(activeID) == nil {
                    promoteNextInstallation(toolIndex, removed: paths)
                }
            }
        }
    }

    private func promoteNextInstallation(_ toolIndex: Int, removed paths: Set<String>) {
        var tool = snapshot.tools[toolIndex]
        tool.resolution?.chain.removeAll { paths.contains($0.path) }
        if let first = tool.resolution?.chain.first, let owner = tool.installation(forExecutablePath: first.path),
           let index = tool.installations.firstIndex(where: { $0.id == owner.id }) {
            tool.installations[index].linkState = .active
            tool.activeInstallationID = owner.id
        }
        tool.health.status = tool.hasUpdate ? .updateAvailable : .healthy
        tool.health.issueIDs = []
        snapshot.issues.removeAll { $0.toolID == tool.id && $0.type == .pathConflict }
        snapshot.tools[toolIndex] = tool
    }

    private func mutateInstallation(_ target: OperationTarget, _ change: (inout ToolInstallation) -> Void) {
        guard let toolIndex = snapshot.tools.firstIndex(where: { $0.id == target.toolID }),
              let index = snapshot.tools[toolIndex].installations.firstIndex(where: { $0.id == target.installationID })
        else { return }
        change(&snapshot.tools[toolIndex].installations[index])
    }

    private func record(_ plan: OperationPlan, outcome: OperationOutcome, startedAt: Date) {
        let status: CommandHistoryEntry.Status
        var verifiedVersions: [String: String] = [:]
        var exitCode: Int32? = 0
        switch outcome {
        case let .succeeded(versions):
            status = .succeeded
            // History keys versions by installation ID, like the live coordinator.
            for target in plan.targets {
                guard let id = target.installationID, let version = versions[target.packageName] else { continue }
                verifiedVersions[id.rawValue] = version
            }
        case .versionUnchanged, .unverified: status = .unverified
        case let .failed(failure):
            status = .failed
            exitCode = failure.exitCode
        case .cancelled:
            status = .cancelled
            exitCode = nil
        }
        history.append(CommandHistoryEntry(
            id: plan.id, planKind: plan.kind, trigger: plan.trigger, providerID: plan.providerID,
            commands: plan.steps.map(OperationText.stepText), targets: plan.targets,
            verifiedVersions: verifiedVersions, status: status, exitCode: exitCode,
            startedAt: startedAt, finishedAt: .now
        ))
    }

    private func genericChecks(provider: ProviderID, detail: String) -> [PreflightCheck] {
        [
            PreflightCheck(kind: .providerAvailable, outcome: .passed, detail: detail),
            PreflightCheck(kind: .ownershipConfirmed, outcome: .passed),
            PreflightCheck(kind: .writableLocation, outcome: .passed),
            PreflightCheck(kind: .networkRequired, outcome: .info),
        ]
    }

    private func pause(milliseconds: Double) async throws {
        guard pace > 0 else { return }
        try await Task.sleep(for: .milliseconds(milliseconds * pace))
    }
}
