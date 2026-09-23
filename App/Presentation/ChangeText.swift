import CLIStateDomain
import SwiftUI

/// Localized wording for environment changes (table `Changes`).
enum ChangeText {
    static func title(_ change: EnvironmentChange) -> String {
        let name = change.toolName ?? change.toolID?.rawValue ?? change.subject ?? ""
        let subject = change.subject ?? ""
        switch change.kind {
        case .toolAdded: return String(localized: "\(name) was installed", table: "Changes")
        case .toolRemoved: return String(localized: "\(name) was removed", table: "Changes")
        case .installationAdded: return String(localized: "New installation of \(name)", table: "Changes")
        case .installationRemoved: return String(localized: "An installation of \(name) was removed", table: "Changes")
        case .versionChanged: return String(localized: "\(name) version changed", table: "Changes")
        case .activeExecutableChanged: return String(localized: "Terminal now runs a different \(subject)", table: "Changes")
        case .providerChanged: return String(localized: "\(name) is now installed via another provider", table: "Changes")
        case .pathEntryAdded: return String(localized: "PATH entry added", table: "Changes")
        case .pathEntryRemoved: return String(localized: "PATH entry removed", table: "Changes")
        case .pathEntryMoved: return String(localized: "PATH order changed", table: "Changes")
        case .serviceStarted: return String(localized: "Service \(subject) started", table: "Changes")
        case .serviceStopped: return String(localized: "Service \(subject) stopped", table: "Changes")
        case .unrecognizedToolsAdded:
            let count = change.count ?? 0
            return String(localized: "\(count) unrecognized executables appeared", table: "Changes")
        case .unrecognizedToolsRemoved:
            let count = change.count ?? 0
            return String(localized: "\(count) unrecognized executables disappeared", table: "Changes")
        }
    }

    static func symbol(_ kind: EnvironmentChangeKind) -> String {
        switch kind {
        case .toolAdded, .installationAdded, .unrecognizedToolsAdded: "plus.circle"
        case .toolRemoved, .installationRemoved, .unrecognizedToolsRemoved: "minus.circle"
        case .versionChanged: "arrow.up.arrow.down.circle"
        case .activeExecutableChanged: Symbol.active
        case .providerChanged: "arrow.left.arrow.right.circle"
        case .pathEntryAdded, .pathEntryRemoved, .pathEntryMoved: Symbol.path
        case .serviceStarted: Symbol.running
        case .serviceStopped: Symbol.stopped
        }
    }

    static func tint(_ kind: EnvironmentChangeKind) -> Color {
        switch kind {
        case .toolAdded, .installationAdded, .serviceStarted, .unrecognizedToolsAdded: DS.Palette.success
        case .activeExecutableChanged, .providerChanged: DS.Palette.highlight
        default: DS.Palette.textSecondary
        }
    }

    static func origin(_ origin: ChangeOrigin) -> String {
        guard origin.kind == .clistate else { return String(localized: "External change", table: "Changes") }
        let operation = origin.operation.map(operationName) ?? String(localized: "operation", table: "Changes")
        return String(localized: "By CLI State (\(operation))", table: "Changes")
    }

    static func originHelp(_ origin: ChangeOrigin) -> String {
        origin.kind == .clistate
            ? String(localized: "Matches an operation CLI State ran between these two scans. See Operations.", table: "Changes")
            : String(localized: "No operation CLI State ran explains this, e.g. a command typed in Terminal.", table: "Changes")
    }

    static func originSymbol(_ origin: ChangeOrigin) -> String {
        origin.kind == .clistate ? Symbol.evidence : Symbol.terminal
    }

    static func operationName(_ kind: OperationKind) -> String {
        switch kind {
        case .update, .selfUpdate: String(localized: "update", table: "Changes")
        case .install: String(localized: "install", table: "Changes")
        case .uninstall: String(localized: "uninstall", table: "Changes")
        case .moveToTrash: String(localized: "move to Trash", table: "Changes")
        case .cleanup: String(localized: "cleanup", table: "Changes")
        case .service(.start): String(localized: "start service", table: "Changes")
        case .service(.stop): String(localized: "stop service", table: "Changes")
        case .service(.restart): String(localized: "restart service", table: "Changes")
        case .refreshMetadata: String(localized: "refresh", table: "Changes")
        }
    }

    static func filterTitle(_ filter: ChangeTimelineModel.TypeFilter) -> String {
        switch filter {
        case .all: String(localized: "All Changes", table: "Changes")
        case .versions: String(localized: "Versions", table: "Changes")
        case .installs: String(localized: "Installed and Removed", table: "Changes")
        case .active: String(localized: "Active Executable", table: "Changes")
        case .providers: String(localized: "Installed Via", table: "Changes")
        case .path: String(localized: "PATH", table: "Changes")
        case .services: String(localized: "Services", table: "Changes")
        }
    }

    static func dayTitle(_ date: Date, calendar: Calendar = .current, now: Date = .now) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today", table: "Changes") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday", table: "Changes")
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day().weekday(.abbreviated))
    }
}
