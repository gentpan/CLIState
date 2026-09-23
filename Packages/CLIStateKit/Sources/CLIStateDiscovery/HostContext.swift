import Darwin
import Foundation

/// The app's own process identity and environment. Injected so discovery can be
/// tested without depending on the machine running the tests.
public struct HostContext: Hashable, Sendable {
    public var userName: String
    public var homeDirectory: String
    /// `pw_shell` from the user database, if available.
    public var loginShell: String?
    public var temporaryDirectory: String
    /// The app process environment (may contain secrets; never persisted).
    public var environment: [String: String]

    public init(
        userName: String,
        homeDirectory: String,
        loginShell: String?,
        temporaryDirectory: String,
        environment: [String: String]
    ) {
        self.userName = userName
        self.homeDirectory = homeDirectory
        self.loginShell = loginShell
        self.temporaryDirectory = temporaryDirectory
        self.environment = environment
    }

    /// Reads the current user from `getpwuid_r(getuid())` and the process environment.
    public static func current() -> HostContext {
        let environment = ProcessInfo.processInfo.environment
        let entry = PasswordEntry.current()
        let temporary = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return HostContext(
            userName: entry?.name ?? environment["USER"] ?? NSUserName(),
            homeDirectory: entry?.home ?? environment["HOME"] ?? NSHomeDirectory(),
            loginShell: entry?.shell,
            temporaryDirectory: temporary,
            environment: environment
        )
    }

    /// `LANG` passed to the login shell; a UTF-8 default keeps output decodable
    /// when the app was launched without one (e.g. from Finder).
    var language: String {
        if let lang = environment["LANG"], !lang.isEmpty { return lang }
        return "en_US.UTF-8"
    }
}

private struct PasswordEntry {
    var name: String?
    var home: String?
    var shell: String?

    static func current() -> PasswordEntry? {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let suggested = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
        var buffer = [CChar](repeating: 0, count: suggested > 0 ? suggested : 16_384)
        let status = getpwuid_r(getuid(), &record, &buffer, buffer.count, &result)
        guard status == 0, result != nil else { return nil }
        func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
            guard let pointer else { return nil }
            let value = String(cString: pointer)
            return value.isEmpty ? nil : value
        }
        return PasswordEntry(name: string(record.pw_name), home: string(record.pw_dir), shell: string(record.pw_shell))
    }
}
