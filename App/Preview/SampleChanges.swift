import CLIStateDomain
import Foundation

extension PreviewActions {
    func loadChangeEvents() async -> [EnvironmentChangeEvent] {
        SampleChanges.events()
    }
}

/// A week of plausible environment changes matching `SampleSnapshot` and its history.
enum SampleChanges {
    static let home = SampleSnapshot.home

    static func events(now: Date = .now) -> [EnvironmentChangeEvent] {
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        func clistate(_ operation: OperationKind, _ trigger: OperationTrigger = .user) -> ChangeOrigin {
            ChangeOrigin(kind: .clistate, operation: operation, trigger: trigger)
        }
        return [
            EnvironmentChangeEvent(detectedAt: ago(0.7), previousCapturedAt: ago(5), depth: .fast, toolCount: 31, changes: [
                EnvironmentChange(kind: .versionChanged, toolID: "php", toolName: "PHP", category: .runtime, installationID: "homebrew:php", provider: .homebrew, from: "8.5.6", to: "8.5.7", subject: "php"),
                EnvironmentChange(kind: .versionChanged, toolID: "homebrew.aom", toolName: "aom", category: .dependency, installationID: "homebrew:aom", provider: .homebrew, from: "3.14.0", to: "3.14.1"),
                EnvironmentChange(kind: .activeExecutableChanged, toolID: "node", toolName: "Node.js", category: .runtime, installationID: .path("\(home)/.local/bin/node"), provider: .standalone, previousProvider: .homebrew, from: "/opt/homebrew/bin/node", to: "\(home)/.local/bin/node", subject: "node"),
                EnvironmentChange(kind: .pathEntryAdded, to: "3", subject: "\(home)/.bun/bin"),
            ]),
            EnvironmentChangeEvent(detectedAt: ago(5), previousCapturedAt: ago(20), depth: .fast, toolCount: 31, changes: [
                EnvironmentChange(kind: .serviceStopped, toolID: "caddy", toolName: "Caddy", category: .developerTool, installationID: "homebrew:caddy", provider: .homebrew, from: "running", to: "stopped", subject: "caddy"),
            ]),
            EnvironmentChangeEvent(detectedAt: ago(26), previousCapturedAt: ago(30), depth: .deep, toolCount: 30, changes: [
                EnvironmentChange(kind: .versionChanged, toolID: "claude-code", toolName: "Claude Code", category: .aiCLI, installationID: "native:claude-code", provider: .native, from: "2.1.230", to: "2.1.234", subject: "claude", origin: clistate(.selfUpdate, .automaticPolicy)),
                EnvironmentChange(kind: .toolAdded, toolID: "kimi-cli", toolName: "Kimi CLI", category: .aiCLI, installationID: "uv:kimi-cli", provider: .uv, to: "1.49.0", subject: "kimi"),
            ]),
            EnvironmentChangeEvent(detectedAt: ago(50), previousCapturedAt: ago(52), depth: .fast, toolCount: 29, changes: [
                EnvironmentChange(kind: .versionChanged, toolID: "gh", toolName: "GitHub CLI", category: .developerTool, installationID: "homebrew:gh", provider: .homebrew, from: "2.91.0", to: "2.92.0", subject: "gh", origin: clistate(.update)),
            ]),
            EnvironmentChangeEvent(detectedAt: ago(75), previousCapturedAt: ago(96), depth: .fast, toolCount: 29, changes: [
                EnvironmentChange(kind: .providerChanged, toolID: "uv", toolName: "uv", category: .packageManager, installationID: "native:uv", provider: .native, previousProvider: .homebrew, from: "0.11.6", to: "0.11.8", subject: "uv"),
                EnvironmentChange(kind: .pathEntryMoved, from: "11", to: "10", subject: "\(home)/.local/bin"),
                EnvironmentChange(kind: .unrecognizedToolsAdded, category: .unrecognized, subject: "unrecognized", count: 7, names: ["antigravity", "lms", "mavis", "windsurf", "windsurf-cli"]),
            ]),
            EnvironmentChangeEvent(detectedAt: ago(150), previousCapturedAt: ago(151), depth: .fast, toolCount: 28, changes: [
                EnvironmentChange(kind: .installationRemoved, toolID: "php", toolName: "PHP", category: .runtime, installationID: "homebrew:php@8.3", provider: .homebrew, from: "8.3.20", subject: "php", origin: clistate(.uninstall)),
            ]),
            EnvironmentChangeEvent(detectedAt: ago(190), depth: .fast, isBaseline: true, toolCount: 28, changes: []),
        ]
    }
}

/// Release-cycle support for the sample runtimes, as a deep scan would fill it in.
enum SampleEndOfLife {
    private static let rows: [InstallationID: (product: String, cycle: String, eol: String?, latest: String)] = [
        "homebrew:php": ("php", "8.5", "2029-12-31", "8.5"),
        "homebrew:php@8.2": ("php", "8.2", "2026-12-31", "8.5"),
        "homebrew:python@3.14": ("python", "3.14", "2030-10-31", "3.14"),
        .path("/usr/bin/python3"): ("python", "3.9", "2025-10-31", "3.14"),
        "homebrew:go": ("go", "1.27", nil, "1.27"),
        "homebrew:node": ("nodejs", "26", "2029-04-30", "26"),
        .path("\(SampleSnapshot.home)/.local/bin/node"): ("nodejs", "26", "2029-04-30", "26"),
        "homebrew:postgresql@17": ("postgresql", "17", "2029-11-08", "18"),
    ]

    static func apply(to snapshot: inout EnvironmentSnapshot, now: Date) {
        for toolIndex in snapshot.tools.indices {
            for index in snapshot.tools[toolIndex].installations.indices {
                let id = snapshot.tools[toolIndex].installations[index].id
                guard let row = rows[id] else { continue }
                let eol = row.eol.flatMap { try? Date($0, strategy: Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()) }
                snapshot.tools[toolIndex].installations[index].support = RuntimeSupportStatus(
                    product: row.product, cycle: row.cycle, phase: phase(eol, now: now), endOfLifeDate: eol,
                    latestSupportedCycle: row.latest, checkedAt: now.addingTimeInterval(-2 * 86400)
                )
            }
        }
        // macOS's Python 3.9 is past end of life: an info issue, since Apple updates it.
        if let python = snapshot.tools.firstIndex(where: { $0.id == "python" }) {
            let issue = HealthIssue(
                type: .runtimeEndOfLife, severity: .info, subject: "python", toolID: "python",
                installationIDs: [.path("/usr/bin/python3")], paths: ["/usr/bin/python3"],
                details: ["product": "python", "cycle": "3.9", "phase": "ended", "eol": "2025-10-31", "latestCycle": "3.14", "systemManaged": "true", "version": "3.9.6"],
                suggestedAction: .openTool("python")
            )
            snapshot.issues.append(issue)
            snapshot.tools[python].health.issueIDs.append(issue.id)
        }
    }

    private static func phase(_ eol: Date?, now: Date) -> RuntimeSupportPhase {
        guard let eol else { return .supported }
        if eol <= now { return .ended }
        return eol.timeIntervalSince(now) <= 90 * 86400 ? .endingSoon : .supported
    }
}
