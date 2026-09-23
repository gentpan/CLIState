import CLIStateDomain
import CLIStateTestSupport
import Foundation
@testable import CLIStateDiscovery

enum DiscoveryFixtures {
    static let home = "/Users/tester"

    static func context(
        loginShell: String? = "/bin/zsh",
        environment: [String: String] = [:]
    ) -> HostContext {
        var base = [
            "HOME": home,
            "USER": "tester",
            "LOGNAME": "tester",
            "TMPDIR": "/var/folders/xy/T/",
            "LANG": "zh_CN.UTF-8",
            "PATH": "/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin",
            "XPC_SERVICE_NAME": "application.dev.clistate",
        ]
        base.merge(environment) { _, new in new }
        return HostContext(
            userName: "tester",
            homeDirectory: home,
            loginShell: loginShell,
            temporaryDirectory: "/var/folders/xy/T/",
            environment: base
        )
    }

    static let zsh = ShellDescriptor(executable: "/bin/zsh", kind: .zsh)

    /// Builds stdout the way the login shell script prints it.
    static func shellOutput(
        environment: [(String, String)],
        shadowLines: [String] = [],
        before: String = "",
        after: String = ""
    ) -> Data {
        var data = Data(before.utf8)
        data.append(Data("\n__CLISTATE_BEGIN__\n".utf8))
        for (key, value) in environment {
            data.append(Data("\(key)=\(value)".utf8))
            data.append(0)
        }
        data.append(Data("\n__CLISTATE_SHADOWS__\n".utf8))
        for line in shadowLines {
            data.append(Data("\(line)\n".utf8))
        }
        data.append(Data("\n__CLISTATE_END__\n".utf8))
        data.append(Data(after.utf8))
        return data
    }

    /// The clean login-shell PATH captured on the developer Mac (F3), home redacted.
    static let developerPATH: [String] = [
        "~/Library/Application Support/Herd/bin/",
        "~/.grok/bin",
        "~/.opencode/bin",
        "~/.kimi-code/bin",
        "~/.mimocode/bin",
        "~/.mavis/bin",
        "~/.bun/bin",
        "~/.cargo/bin",
        "~/.mavis/bin",
        "~/.local/bin",
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/System/Cryptexes/App/usr/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin",
        "/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin",
        "/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/appleinternal/bin",
        "/pkg/env/global/bin",
        "/Library/Apple/usr/bin",
    ].map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 }

    /// Filesystem matching `developerPATH`. The Herd, cryptexd codex and /pkg
    /// directories do not exist.
    static func developerMac() -> InMemoryFileSystem {
        let fs = InMemoryFileSystem(home: home)
        for directory in [
            "~/.grok/bin", "~/.opencode/bin", "~/.kimi-code/bin", "~/.mimocode/bin", "~/.mavis/bin",
            "~/.bun/bin", "~/.cargo/bin", "~/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/System/Cryptexes/App/usr/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "/Library/Apple/usr/bin",
        ] {
            fs.addDirectory(directory.hasPrefix("~/") ? home + directory.dropFirst() : directory)
        }

        fs.addExecutable("\(home)/.local/opt/node-v26.2.0-darwin-arm64/bin/node")
        fs.addSymlink("\(home)/.local/bin/node", to: "\(home)/.local/opt/node-v26.2.0-darwin-arm64/bin/node")
        fs.addExecutable("\(home)/.local/share/claude/versions/2.1.234")
        fs.addSymlink("\(home)/.local/bin/claude", to: "\(home)/.local/share/claude/versions/2.1.234")

        fs.addExecutable("/opt/homebrew/Cellar/node/26.7.0/bin/node")
        fs.addSymlink("/opt/homebrew/bin/node", to: "../Cellar/node/26.7.0/bin/node")
        fs.addSymlink("/opt/homebrew/bin/codexbar", to: "/opt/homebrew/Caskroom/codexbar/0.18.0/CodexBar.app/Contents/Helpers/CodexBarCLI")
        // node + python3 + 717 generated = 719 executables in /opt/homebrew/bin.
        for index in 0..<717 {
            let name = String(format: "brewtool%03d", index)
            if index.isMultiple(of: 2) {
                fs.addExecutable("/opt/homebrew/Cellar/\(name)/1.0/bin/\(name)")
                fs.addSymlink("/opt/homebrew/bin/\(name)", to: "../Cellar/\(name)/1.0/bin/\(name)")
            } else {
                fs.addExecutable("/opt/homebrew/bin/\(name)")
            }
        }

        fs.addExecutable("/usr/bin/git")
        fs.addExecutable("/usr/bin/python3")
        fs.addExecutable("/bin/zsh")
        fs.addExecutable("/bin/bash")
        fs.addExecutable("/bin/sh")
        fs.addExecutable("/System/Cryptexes/App/usr/bin/curl")
        fs.addExecutable("/opt/homebrew/bin/python3")
        fs.addExecutable("\(home)/.mavis/bin/mavis")
        return fs
    }
}
