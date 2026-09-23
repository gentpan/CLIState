import CLIStateDomain
import Foundation

/// Read-only command budgets. Fast scans stay local; deep scans and dry runs may
/// touch the network or walk large directories.
public enum ScanTimeout {
    public static let fast: Duration = .seconds(30)
    public static let deep: Duration = .seconds(60)
}

/// Thin wrapper that turns command results into provider errors and warnings.
struct CommandInvoker: Sendable {
    let providerID: ProviderID
    let runner: any CommandRunning

    func run(_ command: Command, context: ProviderContext) async throws -> CommandResult {
        do {
            return try await runner.run(command, environment: context.execution)
        } catch let error as CommandError {
            throw ProviderError.commandFailed(providerID, command: command.displayString, exitCode: -1, stderr: String(describing: error))
        }
    }

    /// Throws `commandFailed` unless the process exited with 0.
    func runChecked(_ command: Command, context: ProviderContext) async throws -> CommandResult {
        let result = try await run(command, context: context)
        guard result.succeeded else { throw failure(command, result) }
        return result
    }

    func failure(_ command: Command, _ result: CommandResult) -> ProviderError {
        let stderr = result.termination == .timedOut ? "timed out" : result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(providerID, command: command.displayString, exitCode: result.exitCode, stderr: stderr)
    }
}

enum OutputText {
    /// Removes ANSI escape sequences some tools emit even without a TTY.
    static func strippingANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    static func lines(_ text: String) -> [String] {
        strippingANSI(text).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    static func firstLine(_ text: String) -> String? {
        lines(text).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// Splits stderr into warnings. A block starts at a `Warning:` / `Error:` /
    /// `npm warn` style line and absorbs the indented or free-form lines after it,
    /// so a multi-line Homebrew notice (untrusted taps) stays one warning.
    static func warnings(fromStderr stderr: String) -> [String] {
        var blocks: [[String]] = []
        for line in lines(stderr) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if startsBlock(trimmed) || blocks.isEmpty {
                if trimmed.isEmpty { continue }
                blocks.append([line])
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks
            .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func startsBlock(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["warning:", "error:", "npm warn", "npm err", "npm notice"].contains { lower.hasPrefix($0) }
    }

    /// Error lines only, for preflight details.
    static func errorSummary(_ stderr: String) -> String {
        let errors = warnings(fromStderr: stderr).filter { $0.lowercased().hasPrefix("error") }
        return (errors.isEmpty ? warnings(fromStderr: stderr) : errors).joined(separator: "\n")
    }
}

enum DiskUsage {
    /// `du -sk` is a fixed system tool, not something resolved from PATH.
    static let executable = "/usr/bin/du"

    static func command(path: String) -> Command {
        Command(executable: executable, arguments: ["-sk", path], timeout: ScanTimeout.deep)
    }

    /// `12345\t/path` → bytes.
    static func parseBytes(_ output: String) -> Int64? {
        guard let line = OutputText.firstLine(output),
              let token = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
              let kilobytes = Int64(token)
        else { return nil }
        return kilobytes * 1024
    }
}

extension ProviderContext {
    func requireExecutable(_ name: String, provider: ProviderID) throws -> String {
        guard let path = resolveExecutable(name) else { throw ProviderError.unavailable(provider) }
        return path
    }

    /// An allowlisted shell variable that names a directory (`CARGO_HOME`), or
    /// `nil` when unset or not absolute. Trailing slashes are dropped so layout
    /// roots compare as prefixes.
    func persistedDirectory(_ key: String) -> String? {
        guard var value = discovery.session.environment.variables[key], value.hasPrefix("/") else { return nil }
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

enum OutputPath {
    /// First non-empty line when it is an absolute path.
    static func absolute(_ output: String) -> String? {
        OutputText.firstLine(output).flatMap { $0.hasPrefix("/") ? $0 : nil }
    }
}

extension ProviderTool {
    var operationTarget: OperationTarget {
        OperationTarget(
            installationID: installationID,
            packageName: packageName,
            displayName: displayName ?? packageName,
            fromVersion: activeVersion ?? installedVersions.last,
            toVersion: latestVersion
        )
    }
}

extension Array where Element == ProviderTool {
    /// The same package selected twice becomes one target.
    func uniquedByInstallation() -> [ProviderTool] {
        var seen = Set<InstallationID>()
        return filter { seen.insert($0.installationID).inserted }
    }
}

extension Array where Element: Hashable {
    /// Order-preserving de-duplication; brew repeats the same notice per command.
    func uniquedPreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
