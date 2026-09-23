import CLIStateDomain
import Foundation

/// Matches installed versions to release cycles and raises `runtimeEndOfLife`
/// issues. Pure: cycle data is passed in, time comes from `now`.
public struct EndOfLifeAnalyzer: Sendable {
    /// Support ending within this window is reported as `endingSoon`.
    public static let reminderWindow: TimeInterval = 90 * 24 * 3600

    public let registry: ToolRegistry

    public init(registry: ToolRegistry = .standard) {
        self.registry = registry
    }

    /// Products needed for these tools, so only those are loaded.
    public func products(for tools: [Tool]) -> Set<String> {
        Set(tools.compactMap { definition(for: $0)?.product })
    }

    /// Fills `ToolInstallation.support` and returns one issue per tool whose active or
    /// confirmed installation is past, or near, its end of life.
    public func apply(tools: [Tool], products: [String: EndOfLifeProduct], now: Date) -> (tools: [Tool], issues: [HealthIssue]) {
        var result = tools
        var issues: [HealthIssue] = []
        for toolIndex in result.indices {
            guard let definition = definition(for: result[toolIndex]), let product = products[definition.product] else { continue }
            for index in result[toolIndex].installations.indices {
                let installation = result[toolIndex].installations[index]
                result[toolIndex].installations[index].support = Self.matches(installation, hints: definition.pathHints)
                    ? Self.status(for: installation.version?.value, definition: definition, product: product, now: now)
                    : nil
            }
            if let issue = issue(for: result[toolIndex]) { issues.append(issue) }
        }
        return (result, issues)
    }

    private func definition(for tool: Tool) -> EndOfLifeDefinition? {
        tool.identity.registryID.flatMap { registry.definition(ToolID($0))?.endOfLife }
    }

    private func issue(for tool: Tool) -> HealthIssue? {
        // The active installation is what Terminal runs; confirmed ones are real installs the user keeps.
        let considered = tool.installations.compactMap { installation -> (installation: ToolInstallation, support: RuntimeSupportStatus)? in
            guard let support = installation.support, support.phase != .supported,
                  installation.id == tool.activeInstallationID || installation.ownership.confidence == .confirmed
            else { return nil }
            return (installation, support)
        }
        guard let (worst, support) = considered.max(by: { Self.isLessUrgent($0.support, than: $1.support) }) else { return nil }
        let affected = considered.filter { $0.support.phase == support.phase }.map(\.installation)
        // macOS's own runtimes (e.g. /usr/bin/python3 3.9) are Apple's to update.
        let onlySystem = affected.allSatisfy(\.isSystemManaged)
        let severity: HealthSeverity = support.phase == .ended && !onlySystem ? .warning : .info

        var details: [String: String] = [
            "product": support.product,
            "cycle": support.cycle,
            "phase": support.phase.rawValue,
            "systemManaged": onlySystem ? "true" : "false",
        ]
        if let date = support.endOfLifeDate { details["eol"] = date.formatted(EndOfLifeDecoder.dayFormat) }
        if let latest = support.latestSupportedCycle { details["latestCycle"] = latest }
        if let version = worst.version?.value.rawValue { details["version"] = version }
        return HealthIssue(
            type: .runtimeEndOfLife, severity: severity, subject: tool.id.rawValue, toolID: tool.id,
            installationIDs: affected.map(\.id),
            paths: affected.compactMap { installation in
                (installation.executables.first { $0.name == tool.resolution?.command } ?? installation.executables.first)?.path
            },
            details: details,
            suggestedAction: .openTool(tool.id)
        )
    }

    private static func isLessUrgent(_ lhs: RuntimeSupportStatus, than rhs: RuntimeSupportStatus) -> Bool {
        if lhs.phase != rhs.phase { return lhs.phase < rhs.phase }
        // Same phase: the earlier end date is more urgent.
        return (lhs.endOfLifeDate ?? .distantFuture) > (rhs.endOfLifeDate ?? .distantFuture)
    }

    static func matches(_ installation: ToolInstallation, hints: [String]) -> Bool {
        guard !hints.isEmpty else { return true }
        let paths = [installation.installPrefix] + installation.executables.flatMap { [$0.path, $0.resolvedPath] }
        let haystack = paths.compactMap { $0?.lowercased() }
        return hints.contains { hint in haystack.contains { $0.contains(hint.lowercased()) } }
    }

    // MARK: Matching

    public static func status(for version: ToolVersion?, definition: EndOfLifeDefinition, product: EndOfLifeProduct, now: Date) -> RuntimeSupportStatus? {
        guard let version, let cycle = cycle(for: version, scheme: definition.scheme, in: product.cycles) else { return nil }
        return RuntimeSupportStatus(
            product: product.slug,
            cycle: cycle.name,
            phase: phase(of: cycle, now: now),
            endOfLifeDate: cycle.endOfLifeDate,
            latestSupportedCycle: latestSupportedCycle(in: product.cycles, now: now),
            checkedAt: product.fetchedAt
        )
    }

    public static func cycle(for version: ToolVersion, scheme: EndOfLifeDefinition.CycleScheme, in cycles: [EndOfLifeCycle]) -> EndOfLifeCycle? {
        guard let semantic = version.semantic, let major = semantic.components.first else { return nil }
        let minor = semantic.components.count > 1 ? semantic.components[1] : nil
        let byName = Dictionary(cycles.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let majorMinor = minor.map { "\(major).\($0)" }
        switch scheme {
        case .major:
            return byName[String(major)]
        case .majorMinor:
            return majorMinor.flatMap { byName[$0] }
        case .automatic:
            return majorMinor.flatMap { byName[$0] } ?? byName[String(major)]
        case .javaFeature:
            let feature = major == 1 ? minor : major
            return feature.flatMap { byName[String($0)] }
        }
    }

    public static func phase(of cycle: EndOfLifeCycle, now: Date) -> RuntimeSupportPhase {
        if let date = cycle.endOfLifeDate {
            if date <= now || cycle.isEndOfLife == true { return .ended }
            return date.timeIntervalSince(now) <= reminderWindow ? .endingSoon : .supported
        }
        return cycle.isEndOfLife == true ? .ended : .supported
    }

    /// Newest released cycle that is still supported.
    static func latestSupportedCycle(in cycles: [EndOfLifeCycle], now: Date) -> String? {
        let supported = cycles.enumerated().filter { _, cycle in
            (cycle.releaseDate.map { $0 <= now } ?? true) && phase(of: cycle, now: now) != .ended
        }
        // Sources list newest first, but not strictly (Temurin 11 after 17), so prefer release dates.
        let newest = supported.max { lhs, rhs in
            switch (lhs.element.releaseDate, rhs.element.releaseDate) {
            case let (l?, r?) where l != r: return l < r
            default: return lhs.offset > rhs.offset
            }
        }
        return newest?.element.name
    }
}
