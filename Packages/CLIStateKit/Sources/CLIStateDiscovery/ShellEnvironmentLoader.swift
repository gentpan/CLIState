import CLIStateDomain
import Foundation

/// Captures the environment a fresh Terminal window would have (F2) by running the
/// login shell under `env -i` with a minimal environment, and detects shell
/// aliases/functions that shadow PATH lookups (F4).
public struct ShellEnvironmentLoader: Sendable {
    public static let timeout: Duration = .seconds(8)
    public static let envExecutable = "/usr/bin/env"
    public static let pathHelperExecutable = "/usr/libexec/path_helper"
    public static let defaultPATH = "/usr/bin:/bin:/usr/sbin:/sbin"

    private let runner: CommandRunning
    private let context: HostContext
    private let now: @Sendable () -> Date

    public init(runner: CommandRunning, context: HostContext, now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.context = context
        self.now = now
    }

    /// Never fails for shell problems (those produce a `.fallback` session); only
    /// rethrows cancellation.
    public func load(shell: ShellDescriptor, shadowCandidates: [String]) async throws -> ShellSession {
        let command = Self.loginShellCommand(shell: shell, shadowCandidates: shadowCandidates, context: context)
        let failure: String
        do {
            let result = try await runner.run(command, environment: ExecutionEnvironment(variables: context.environment))
            switch result.termination {
            case .timedOut:
                failure = "login shell timed out"
            case let .signaled(signal):
                failure = "login shell terminated by signal \(signal)"
            case .exited:
                if let output = LoginShellScript.parse(result.stdout) {
                    if output.variables["PATH"] != nil {
                        return session(shell: shell, variables: output.variables, shadows: output.shadows)
                    }
                    failure = "login shell reported no PATH"
                } else if result.exitCode != 0 {
                    failure = "login shell exited with status \(result.exitCode)"
                } else {
                    failure = "login shell output markers missing"
                }
            }
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            failure = "login shell could not start: \(error)"
        }
        try Task.checkCancellation()
        return try await fallbackSession(shell: shell, failure: failure)
    }

    /// `/usr/bin/env -i HOME=… USER=… LOGNAME=… SHELL=… TMPDIR=… LANG=… TERM=dumb <shell> -l -i -c <script>`
    public static func loginShellCommand(shell: ShellDescriptor, shadowCandidates: [String], context: HostContext) -> Command {
        let assignments = cleanEnvironment(shell: shell, context: context)
            .sorted { order($0.key) < order($1.key) }
            .map { "\($0.key)=\($0.value)" }
        let script = LoginShellScript.make(kind: shell.kind, shadowCandidates: shadowCandidates)
        return Command(
            executable: envExecutable,
            arguments: ["-i"] + assignments + [shell.executable, "-l", "-i", "-c", script],
            workingDirectory: context.homeDirectory,
            timeout: timeout
        )
    }

    public static func pathHelperCommand() -> Command {
        Command(executable: pathHelperExecutable, arguments: ["-s"], timeout: .seconds(2))
    }

    /// Extracts the value from `PATH="…"; export PATH;`.
    public static func parsePathHelperOutput(_ output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let prefix = "PATH=\""
            guard line.hasPrefix(prefix) else { continue }
            let rest = line.dropFirst(prefix.count)
            if let terminator = rest.range(of: "\"; export PATH;") {
                return String(rest[..<terminator.lowerBound])
            }
            if let quote = rest.lastIndex(of: "\"") {
                return String(rest[..<quote])
            }
        }
        return nil
    }

    // MARK: Private

    private static let assignmentOrder = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM"]

    private static func order(_ key: String) -> Int {
        assignmentOrder.firstIndex(of: key) ?? assignmentOrder.count
    }

    private static func cleanEnvironment(shell: ShellDescriptor, context: HostContext) -> [String: String] {
        [
            "HOME": context.homeDirectory,
            "USER": context.userName,
            "LOGNAME": context.userName,
            "SHELL": shell.executable,
            "TMPDIR": context.temporaryDirectory,
            "LANG": context.language,
            "TERM": "dumb",
        ]
    }

    private func session(
        shell: ShellDescriptor,
        variables: [String: String],
        shadows: [String: [ShellShadow]],
        source: ShellEnvironmentSource = .loginShell,
        failureReason: String? = nil
    ) -> ShellSession {
        let path = variables["PATH"].map(Self.splitPATH) ?? []
        let environment = ShellEnvironment(
            shell: shell,
            path: path,
            variables: EnvironmentAllowlist.filter(variables),
            shadows: shadows,
            source: source,
            failureReason: failureReason,
            capturedAt: now()
        )
        return ShellSession(environment: environment, execution: ExecutionEnvironment(variables: variables))
    }

    private func fallbackSession(shell: ShellDescriptor, failure: String) async throws -> ShellSession {
        var clean = Self.cleanEnvironment(shell: shell, context: context)
        clean["TERM"] = nil
        // No PATH: path_helper appends the caller's PATH, which would leak the app's
        // inherited environment back in.
        var reason = failure
        var pathValue = Self.defaultPATH
        do {
            let result = try await runner.run(Self.pathHelperCommand(), environment: ExecutionEnvironment(variables: clean))
            if result.succeeded, let parsed = Self.parsePathHelperOutput(result.stdoutString), !parsed.isEmpty {
                pathValue = parsed
            } else {
                reason += "; path_helper unavailable"
            }
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            reason += "; path_helper unavailable"
        }

        var variables = context.environment
        for (key, value) in clean where key == "SHELL" || variables[key]?.isEmpty ?? true {
            variables[key] = value
        }
        variables["PATH"] = pathValue
        return session(shell: shell, variables: variables, shadows: [:], source: .fallback, failureReason: reason)
    }

    static func splitPATH(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        return value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    }
}
