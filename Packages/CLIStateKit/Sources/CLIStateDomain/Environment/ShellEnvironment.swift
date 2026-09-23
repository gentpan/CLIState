import Foundation

public struct ShellDescriptor: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case zsh, bash, fish, sh, other
    }

    public var executable: String
    public var kind: Kind

    public init(executable: String, kind: Kind) {
        self.executable = executable
        self.kind = kind
    }

    public var name: String { (executable as NSString).lastPathComponent }
}

public enum ShellEnvironmentSource: String, Codable, Sendable {
    /// Captured from `<shell> -l -i -c` in a clean environment.
    case loginShell
    /// Login shell failed or timed out; PATH came from `/usr/libexec/path_helper`.
    case fallback
}

/// A shell alias, function or builtin that runs instead of a PATH lookup (F4).
public struct ShellShadow: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case alias, function, builtin, reserved, hashed
    }

    public var name: String
    public var kind: Kind
    public var detail: String?

    public init(name: String, kind: Kind, detail: String? = nil) {
        self.name = name
        self.kind = kind
        self.detail = detail
    }
}

/// Persistable snapshot of the user's terminal environment (§51).
/// `variables` contains only allowlisted keys — never secrets.
public struct ShellEnvironment: Hashable, Codable, Sendable {
    public var shell: ShellDescriptor
    /// Raw PATH entries in order, exactly as the shell reported them.
    public var path: [String]
    public var variables: [String: String]
    public var shadows: [String: [ShellShadow]]
    public var source: ShellEnvironmentSource
    public var failureReason: String?
    public var capturedAt: Date

    public init(
        shell: ShellDescriptor,
        path: [String],
        variables: [String: String],
        shadows: [String: [ShellShadow]] = [:],
        source: ShellEnvironmentSource,
        failureReason: String? = nil,
        capturedAt: Date
    ) {
        self.shell = shell
        self.path = path
        self.variables = variables
        self.shadows = shadows
        self.source = source
        self.failureReason = failureReason
        self.capturedAt = capturedAt
    }
}

/// Result of loading the shell: the persistable part plus the in-memory
/// execution environment.
public struct ShellSession: Sendable {
    public var environment: ShellEnvironment
    public var execution: ExecutionEnvironment

    public init(environment: ShellEnvironment, execution: ExecutionEnvironment) {
        self.environment = environment
        self.execution = execution
    }
}

public enum EnvironmentAllowlist {
    /// Keys that may be written to disk. Allowlist, not blocklist (§106).
    public static let persisted: Set<String> = [
        "PATH", "HOME", "SHELL", "LANG", "LC_ALL", "TMPDIR",
        "HOMEBREW_PREFIX", "HOMEBREW_CELLAR", "HOMEBREW_REPOSITORY",
        "CARGO_HOME", "CARGO_INSTALL_ROOT", "RUSTUP_HOME", "GOPATH", "GOBIN",
        "PNPM_HOME", "BUN_INSTALL", "VOLTA_HOME", "NVM_DIR", "FNM_DIR",
        "MISE_DATA_DIR", "ASDF_DATA_DIR", "PYENV_ROOT", "RBENV_ROOT",
        "PIPX_HOME", "PIPX_BIN_DIR", "UV_TOOL_DIR", "UV_TOOL_BIN_DIR", "XDG_DATA_HOME",
        "JAVA_HOME", "NPM_CONFIG_PREFIX",
    ]

    public static func filter(_ variables: [String: String]) -> [String: String] {
        variables.filter { persisted.contains($0.key) }
    }
}
