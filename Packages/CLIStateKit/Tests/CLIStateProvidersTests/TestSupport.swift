import CLIStateDomain
import CLIStateTestSupport
import Foundation

enum Fixture {
    static func url(_ path: String) -> URL { Fixtures.url(path, in: .module) }
    static func data(_ path: String) throws -> Data { try Fixtures.data(path, in: .module) }
    static func string(_ path: String) throws -> String { try Fixtures.string(path, in: .module) }
}

enum TestContext {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A context whose shell PATH resolves exactly the given `name → path` pairs.
    static func make(_ executables: [String: String], variables: [String: String] = [:]) -> ProviderContext {
        let groups = Dictionary(uniqueKeysWithValues: executables.map { name, path in
            (name, BinaryGroup(executableName: name, candidates: [
                BinaryCandidate(name: name, path: path, pathPriority: 1, isSymlink: false, resolvedPath: nil),
            ]))
        })
        let environment = ShellEnvironment(
            shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh),
            path: ["/opt/homebrew/bin", "/usr/bin", "/bin"],
            variables: variables,
            source: .loginShell,
            capturedAt: now
        )
        let session = ShellSession(environment: environment, execution: ExecutionEnvironment(variables: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]))
        return ProviderContext(discovery: DiscoveryResult(session: session, pathEntries: [], binaries: BinaryInventory(groups: groups)), now: now)
    }

    static let brew = make(["brew": "/opt/homebrew/bin/brew"])
    static let npm = make(["npm": "/Users/tester/.local/bin/npm"])
    static let uv = make(["uv": "/Users/tester/.local/bin/uv"])
    static let pipx = make(["pipx": "/opt/homebrew/bin/pipx"])
    static let pnpm = make(["pnpm": "/Users/tester/Library/pnpm/pnpm"])
    static let cargo = make(["cargo": "/opt/homebrew/bin/cargo"])
    static let empty = make([:])
}

extension StubCommandRunner {
    func stub(_ name: String, _ arguments: [String], fixture path: String, stderr: String = "", exitCode: Int32 = 0) throws {
        stub(name, arguments, result: CommandResult(exitCode: exitCode, stdout: try Fixture.data(path), stderr: Data(stderr.utf8)))
    }

    var commands: [Command] { invocations.map(\.command) }

    func arguments(of name: String) -> [[String]] {
        commands.filter { ($0.executable as NSString).lastPathComponent == name }.map(\.arguments)
    }
}

enum Tools {
    static func formula(_ name: String, active: String? = "1.0", latest: String? = "2.0") -> ProviderTool {
        ProviderTool(providerID: .homebrew, packageName: name, kind: .formula, installedVersions: active.map { [$0] } ?? [], activeVersion: active, latestVersion: latest)
    }

    static func cask(_ name: String) -> ProviderTool {
        ProviderTool(providerID: .homebrew, packageName: name, kind: .cask, installedVersions: ["0.56.4"], activeVersion: "0.56.4", latestVersion: "0.60.0")
    }

    static func npm(_ name: String, root: String = "/Users/tester/.local/opt/node-v26.2.0-darwin-arm64/lib/node_modules") -> ProviderTool {
        ProviderTool(providerID: .npm, instanceID: ProviderInstanceID("npm@\(root)"), packageName: name, kind: .globalPackage, installedVersions: ["1.0.0"], activeVersion: "1.0.0")
    }

    static func uv(_ name: String) -> ProviderTool {
        ProviderTool(providerID: .uv, packageName: name, kind: .tool, installedVersions: ["1.49.0"], activeVersion: "1.49.0", latestVersion: "1.50.0")
    }

    static func pipx(_ name: String, pinned: Bool = false) -> ProviderTool {
        ProviderTool(providerID: .pipx, packageName: name, kind: .tool, installedVersions: ["24.10.0"], activeVersion: "24.10.0", isPinned: pinned)
    }

    static func pnpm(_ name: String, pinned: Bool = false) -> ProviderTool {
        ProviderTool(providerID: .pnpm, packageName: name, kind: .globalPackage, installedVersions: ["5.9.2"], activeVersion: "5.9.2", latestVersion: "5.9.3", isPinned: pinned)
    }

    static func cargo(_ name: String, pinned: Bool = false) -> ProviderTool {
        ProviderTool(providerID: .cargo, packageName: name, kind: .tool, installedVersions: ["0.8.20"], activeVersion: "0.8.20", isPinned: pinned)
    }
}

/// Names that must never reach a package manager as-is (§178).
let hostilePackageNames: [String] = [
    "",
    "-rf",
    "--cask",
    "foo; rm -rf ~",
    "$(whoami)",
    "`whoami`",
    "foo'bar",
    "foo\"bar",
    "foo bar",
    "foo\tbar",
    "foo\nbar",
    "naïve",
    "工具",
    "./local-formula.rb",
    "/tmp/evil.rb",
    "user/../../etc",
    "user//tap",
    "tap/",
    "user/-tap/name",
    "git+https://example.com/x.git",
    "foo|bar",
    "foo&&bar",
    "foo>out",
    "foo*",
    "~/pkg",
    String(repeating: "a", count: 257),
]
