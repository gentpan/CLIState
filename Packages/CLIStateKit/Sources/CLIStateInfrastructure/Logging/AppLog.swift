import CLIStateDomain
import Foundation
import os

/// Unified-logging categories for the whole app (subsystem `com.clistate.app`).
public enum AppLog {
    public static let subsystem = "com.clistate.app"

    public enum Category: String, CaseIterable, Sendable {
        case scan, provider, command, update, service, database, ui
    }

    public static let scan = logger(.scan)
    public static let provider = logger(.provider)
    public static let command = logger(.command)
    public static let update = logger(.update)
    public static let service = logger(.service)
    public static let database = logger(.database)
    public static let ui = logger(.ui)

    public static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    public enum CommandEvent: Sendable {
        case started(pid: Int32)
        case finished(CommandResult)
        case timedOut
        case cancelled
        case launchFailed(any Error)
    }

    /// Logs a command lifecycle event. Only the executable's file name is public;
    /// arguments may contain package names or paths and stay private. The
    /// environment is never logged (C11).
    public static func log(_ command: Command, _ event: CommandEvent, to logger: Logger = AppLog.command) {
        let (name, arguments) = redactableParts(of: command)
        switch event {
        case let .started(pid):
            logger.debug("start \(name, privacy: .public) \(arguments, privacy: .private) pid=\(pid, privacy: .public)")
        case let .finished(result):
            let milliseconds = Int(result.duration / .milliseconds(1))
            let termination = String(describing: result.termination)
            logger.debug("finish \(name, privacy: .public) \(arguments, privacy: .private) exit=\(result.exitCode, privacy: .public) termination=\(termination, privacy: .public) ms=\(milliseconds, privacy: .public)")
        case .timedOut:
            logger.notice("timeout \(name, privacy: .public) \(arguments, privacy: .private)")
        case .cancelled:
            logger.notice("cancel \(name, privacy: .public) \(arguments, privacy: .private)")
        case let .launchFailed(error):
            logger.error("launch failed \(name, privacy: .public) \(arguments, privacy: .private): \(String(describing: error), privacy: .private)")
        }
    }

    /// Splits `displayString` into the executable file name and the quoted arguments.
    static func redactableParts(of command: Command) -> (name: String, arguments: String) {
        let name = (command.executable as NSString).lastPathComponent
        let display = command.displayString
        guard display.hasPrefix(name) else { return (name, "") }
        let rest = display.dropFirst(name.count)
        return (name, String(rest.drop(while: { $0 == " " })))
    }
}
