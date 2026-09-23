import CLIStateDomain
import Foundation

/// Determines the user's login shell: `pw_shell` → `$SHELL` → `/bin/zsh`.
public struct ShellDetector: Sendable {
    public static let defaultShell = "/bin/zsh"

    private let context: HostContext
    private let fileSystem: FileSystem?

    /// When `fileSystem` is given, candidates that are not executable files are skipped
    /// (e.g. a `pw_shell` pointing at an uninstalled fish).
    public init(context: HostContext, fileSystem: FileSystem? = nil) {
        self.context = context
        self.fileSystem = fileSystem
    }

    public func detect() -> ShellDescriptor {
        for candidate in [context.loginShell, context.environment["SHELL"]] {
            guard let candidate, isUsable(candidate) else { continue }
            return ShellDescriptor(executable: candidate, kind: Self.kind(forExecutable: candidate))
        }
        return ShellDescriptor(executable: Self.defaultShell, kind: .zsh)
    }

    public static func kind(forExecutable executable: String) -> ShellDescriptor.Kind {
        var name = (executable as NSString).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() }
        switch name {
        case "zsh": return .zsh
        case "bash": return .bash
        case "fish": return .fish
        case "sh": return .sh
        default: return .other
        }
    }

    private func isUsable(_ path: String) -> Bool {
        // `env` would treat an argument containing `=` as an assignment.
        guard path.hasPrefix("/"), !path.contains("=") else { return false }
        guard let fileSystem else { return true }
        return fileSystem.isExecutableFile(atPath: path)
    }
}
