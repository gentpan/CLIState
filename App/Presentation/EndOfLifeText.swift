import CLIStateDomain
import SwiftUI

/// Localized end-of-life wording (table `Changes`).
enum EndOfLifeText {
    static func issue(_ issue: HealthIssue, name: String) -> IssueText {
        let cycle = issue.details["cycle"] ?? "?"
        let latest = issue.details["latestCycle"]
        let date = issue.details["eol"].flatMap(parseDay).map(format) ?? issue.details["eol"] ?? "?"
        let isSystem = issue.details["systemManaged"] == "true"

        if issue.details["phase"] == RuntimeSupportPhase.endingSoon.rawValue {
            let title = String(localized: "\(name) \(cycle) support ends soon", table: "Changes")
            let message = latest.map { String(localized: "Security fixes for \(name) \(cycle) stop on \(date). Plan a move to \(name) \($0).", table: "Changes") }
                ?? String(localized: "Security fixes for \(name) \(cycle) stop on \(date).", table: "Changes")
            return IssueText(title: title, message: message)
        }

        let title = String(localized: "\(name) \(cycle) is no longer supported", table: "Changes")
        var message = issue.details["eol"] != nil
            ? String(localized: "\(name) \(cycle) stopped receiving security fixes on \(date).", table: "Changes")
            : String(localized: "\(name) \(cycle) no longer receives security fixes.", table: "Changes")
        if let latest {
            message = joined(message, String(localized: "The newest supported release line is \(latest).", table: "Changes"))
        }
        if isSystem {
            message = joined(message, String(localized: "This copy comes with macOS, which updates it; install a newer version if your projects need one.", table: "Changes"))
        }
        return IssueText(title: title, message: message)
    }

    /// Two sentences: a space in English, none after Chinese full stops.
    private static func joined(_ first: String, _ second: String) -> String {
        String(localized: "\(first) \(second)", table: "Changes", comment: "Joins two sentences")
    }

    /// Short state for the installation card: "Supported until Apr 30, 2027" / "Support ends soon" / "No longer supported".
    static func status(_ support: RuntimeSupportStatus) -> String {
        switch support.phase {
        case .supported:
            return support.endOfLifeDate.map { String(localized: "Supported until \(format($0))", table: "Changes") } ?? String(localized: "Supported", table: "Changes")
        case .endingSoon:
            return String(localized: "Support ends soon", table: "Changes")
        case .ended:
            return String(localized: "No longer supported", table: "Changes")
        }
    }

    /// Second line for unsupported cycles: when support ends or ended, and what to move to.
    static func detail(_ support: RuntimeSupportStatus) -> String? {
        guard support.phase != .supported else { return nil }
        var parts: [String] = []
        if let date = support.endOfLifeDate.map(format) {
            parts.append(support.phase == .ended
                ? String(localized: "Ended \(date)", table: "Changes")
                : String(localized: "Ends \(date)", table: "Changes"))
        }
        if let latest = support.latestSupportedCycle, latest != support.cycle {
            parts.append(String(localized: "Newest supported release line: \(latest)", table: "Changes"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func symbol(_ phase: RuntimeSupportPhase) -> String {
        switch phase {
        case .supported: Symbol.latest
        case .endingSoon: "clock.badge.exclamationmark"
        case .ended: Symbol.needsAttention
        }
    }

    static func tint(_ phase: RuntimeSupportPhase) -> Color {
        switch phase {
        case .supported: DS.Palette.success
        case .endingSoon, .ended: DS.Palette.warning
        }
    }

    static func help(_ support: RuntimeSupportStatus) -> String {
        let checked = support.checkedAt.formatted(date: .abbreviated, time: .omitted)
        let cycle = support.cycle
        return String(localized: "Release line \(cycle), from endoflife.date (checked \(checked)).", table: "Changes")
    }

    private static func format(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }

    private static func parseDay(_ text: String) -> Date? {
        try? Date(text, strategy: Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
    }
}
