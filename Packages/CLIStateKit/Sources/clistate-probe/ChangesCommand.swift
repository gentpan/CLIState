import CLIStateApplication
import CLIStateDomain
import CLIStateInfrastructure
import Foundation

/// `clistate-probe changes [--since 7d]`: prints the timeline the app recorded,
/// newest first. Reads the file only; never scans or writes.
func runChangesCommand(_ arguments: [String]) {
    var since: Date?
    if let index = arguments.firstIndex(of: "--since") {
        guard arguments.indices.contains(index + 1), let interval = parseInterval(arguments[index + 1]) else {
            print("usage: clistate-probe changes [--since <N>(h|d|w)]")
            exit(2)
        }
        since = Date().addingTimeInterval(-interval)
    }
    let events: [EnvironmentChangeEvent]
    do {
        events = try JSONChangeEventStore.readEvents(fileURL: JSONChangeEventStore.defaultFileURL())
            .filter { event in since.map { event.detectedAt >= $0 } ?? true }
    } catch {
        print("couldn't read the change timeline: \(error)")
        exit(1)
    }
    let home = LocalFileSystem().homeDirectory
    func tilde(_ text: String?) -> String { text.map { PathRedaction.abbreviatingHome($0, home: home) } ?? "?" }

    let total = events.reduce(0) { $0 + $1.changes.count }
    print("\(events.count) events · \(total) changes\(since.map { " since \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
    for event in events {
        let when = event.detectedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.colon))
        if event.isBaseline {
            print("\n\(when)  baseline (\(event.toolCount) tools, \(event.depth.rawValue) scan)")
            continue
        }
        print("\n\(when)  \(event.changes.count) changes (\(event.depth.rawValue) scan)")
        for change in event.changes {
            let name = change.toolName ?? change.toolID?.rawValue ?? tilde(change.subject)
            var detail: String
            switch change.kind {
            case .versionChanged:
                detail = "\(change.from ?? "?") → \(change.to ?? "?")"
            case .toolAdded, .installationAdded:
                detail = change.to ?? ""
            case .toolRemoved, .installationRemoved:
                detail = change.from ?? ""
            case .providerChanged:
                detail = "\(change.previousProvider?.rawValue ?? "?") → \(change.provider?.rawValue ?? "?")  \(change.from ?? "?") → \(change.to ?? "?")"
            case .activeExecutableChanged:
                detail = "`\(change.subject ?? "?")` \(tilde(change.from)) → \(tilde(change.to))"
            case .pathEntryAdded:
                detail = "#\(change.to ?? "?")"
            case .pathEntryRemoved:
                detail = "was #\(change.from ?? "?")"
            case .pathEntryMoved:
                detail = "#\(change.from ?? "?") → #\(change.to ?? "?")"
            case .serviceStarted, .serviceStopped:
                detail = "\(change.from ?? "?") → \(change.to ?? "?")"
            case .unrecognizedToolsAdded, .unrecognizedToolsRemoved:
                detail = "\(change.count ?? 0): \(change.names.joined(separator: ", "))"
            }
            if let provider = change.provider, ![.providerChanged, .pathEntryAdded, .pathEntryRemoved, .pathEntryMoved].contains(change.kind) {
                detail += "  via \(provider.rawValue)"
            }
            let origin = change.origin.kind == .clistate ? "clistate" : "external"
            print("  \(change.kind.rawValue.padding(toLength: 24, withPad: " ", startingAt: 0)) \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(detail)  [\(origin)]")
        }
    }
}

private func parseInterval(_ text: String) -> TimeInterval? {
    guard let unit = text.last, let value = Double(text.dropLast()), value >= 0 else { return nil }
    switch unit {
    case "h": return value * 3600
    case "d": return value * 86400
    case "w": return value * 7 * 86400
    default: return nil
    }
}
