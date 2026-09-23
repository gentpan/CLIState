import CLIStateDomain
@testable import CLIStateEngine
import CLIStateTestSupport
import Foundation
import Testing

private let testHome = "/Users/tester"

private func installation(_ id: InstallationID, provider: ProviderID, package: String? = nil, prefix: String? = nil, executables: [ExecutableRef] = []) -> ToolInstallation {
    ToolInstallation(
        id: id,
        ownership: Ownership(provider: provider, packageName: package, confidence: .confirmed),
        executables: executables,
        installPrefix: prefix,
        linkState: .active,
        capabilities: ToolCapabilities(canUpdate: true, canUninstall: true)
    )
}

private func tool(_ id: String, name: String? = nil, registryID: String? = nil, installations: [ToolInstallation]) -> Tool {
    Tool(
        id: ToolID(id),
        identity: ToolIdentity(name: name ?? id, displayName: name ?? id, category: .aiCLI, registryID: registryID),
        installations: installations,
        health: ToolHealthState(status: .healthy),
        lastScannedAt: Date(timeIntervalSince1970: 0)
    )
}

private func snapshot(_ tools: [Tool], pathEntries: [String] = []) -> EnvironmentSnapshot {
    let shell = ShellEnvironment(shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh), path: pathEntries, variables: ["HOME": testHome], source: .loginShell, capturedAt: Date(timeIntervalSince1970: 0))
    let entries = pathEntries.enumerated().map { PATHEntry(priority: $0.offset + 1, rawValue: $0.element, normalizedPath: $0.element, status: .ok, source: .userLocal) }
    return EnvironmentSnapshot(capturedAt: Date(timeIntervalSince1970: 0), depth: .fast, shell: shell, pathEntries: entries, brokenSymlinks: [], providers: [], tools: tools, services: [], issues: [])
}

/// Claude Code installed natively, plus gh from Homebrew and uv tools.
private func claudeScenario() -> (InMemoryFileSystem, EnvironmentSnapshot) {
    let fs = InMemoryFileSystem(home: testHome)
    fs.addExecutable("\(testHome)/.local/share/claude/versions/2.1.234")
    fs.addSymlink("\(testHome)/.local/bin/claude", to: "\(testHome)/.local/share/claude/versions/2.1.234")
    fs.addFile("\(testHome)/.claude/settings.json", contents: Data(repeating: 1, count: 100))
    fs.addFile("\(testHome)/.claude/projects/a.jsonl", contents: Data(repeating: 1, count: 900))
    fs.addFile("\(testHome)/.claude.json", contents: Data(repeating: 1, count: 40))
    fs.addFile("\(testHome)/Library/Caches/claude-cli-nodejs/mcp.log", contents: Data(repeating: 1, count: 10))
    fs.addFile("\(testHome)/.config/claude-code/state", contents: Data(repeating: 1, count: 5))
    fs.addDirectory("\(testHome)/Library/Caches/claude-code")
    let claude = tool("claude-code", name: "claude-code", registryID: "claude-code", installations: [
        installation("native:claude-code", provider: .native, package: "claude-code", prefix: "\(testHome)/.local/share/claude",
                     executables: [ExecutableRef(name: "claude", path: "\(testHome)/.local/bin/claude", resolvedPath: "\(testHome)/.local/share/claude/versions/2.1.234")]),
    ])
    let gh = tool("gh", registryID: "gh", installations: [
        installation("homebrew:gh", provider: .homebrew, package: "gh", prefix: "/opt/homebrew/Cellar/gh/2.92.0"),
    ])
    return (fs, snapshot([claude, gh], pathEntries: ["\(testHome)/.local/bin", "/opt/homebrew/bin"]))
}

@Suite("LeftoverScanner")
struct LeftoverScannerTests {
    // MARK: Discovery

    @Test func findsRegistryLeftoversFirstThenExactNames() throws {
        let (fs, snapshot) = claudeScenario()
        let items = LeftoverScanner(fileSystem: fs).leftovers(for: "claude-code", in: snapshot)
        #expect(items.map(\.path) == [
            "\(testHome)/.claude",
            "\(testHome)/.claude.json",
            "\(testHome)/Library/Caches/claude-cli-nodejs",
            "\(testHome)/Library/Caches/claude-code",
            "\(testHome)/.config/claude-code",
        ])
        let claudeDirectory = try #require(items.first)
        #expect(claudeDirectory.kind == .data && claudeDirectory.origin == .registry && claudeDirectory.containsUserData)
        #expect(claudeDirectory.sizeBytes == 1000 && !claudeDirectory.sizeIsLowerBound)
        #expect(items[1].kind == .config && items[1].sizeBytes == 40)
        #expect(items[2].kind == .logs && !items[2].containsUserData)
        #expect(items[3].kind == .cache && items[3].origin == .exactName)
        #expect(items[4].kind == .config && items[4].containsUserData)
    }

    @Test func registryDeclaresOnlyHomeLocationsThatPassTheRules() {
        let registry = ToolRegistry.standard
        let declared = registry.definitions.flatMap { definition in definition.leftoverPaths.map { (definition.id, $0) } }
        #expect(declared.count >= 20)
        let empty = snapshot([])
        let scanner = LeftoverScanner(fileSystem: InMemoryFileSystem(home: testHome))
        for (id, location) in declared {
            #expect(location.path.hasPrefix("~/"))
            let path = PathUtil.expandingTilde(location.path, home: testHome)
            // Only `missing` is acceptable on an empty disk: every location rule must pass.
            #expect(scanner.rejection(for: path, tool: id, in: empty) == .missing, "\(id): \(location.path)")
        }
        #expect(registry.definition("claude-code")?.leftoverPaths.map(\.path) == ["~/.claude", "~/.claude.json", "~/Library/Caches/claude-cli-nodejs"])
        #expect(registry.definition("uv")?.leftoverPaths == [LeftoverLocation("~/.cache/uv", .cache)])
        #expect(registry.definition("gh")?.leftoverPaths == [LeftoverLocation("~/.config/gh", .config)])
        #expect(registry.definition("ffmpeg")?.leftoverPaths.isEmpty == true)
    }

    @Test func worksForToolsNoLongerInstalled() {
        let fs = InMemoryFileSystem(home: testHome)
        fs.addFile("\(testHome)/.gemini/settings.json")
        fs.addDirectory("\(testHome)/Library/Caches/gemini-cli")
        let items = LeftoverScanner(fileSystem: fs).leftovers(for: "gemini-cli", in: snapshot([]))
        #expect(items.map(\.path) == ["\(testHome)/.gemini", "\(testHome)/Library/Caches/gemini-cli"])
        #expect(LeftoverScanner(fileSystem: fs).leftovers(for: "not-a-tool", in: snapshot([])).isEmpty)
    }

    @Test func exactNameMatchIgnoresOtherCasesPrefixesAndScopedPackages() {
        let fs = InMemoryFileSystem(home: testHome)
        fs.addDirectory("\(testHome)/Library/Caches/Codex")          // different case
        fs.addDirectory("\(testHome)/Library/Caches/codex-old")      // prefix
        fs.addDirectory("\(testHome)/Library/Caches/codexx")
        fs.addDirectory("\(testHome)/.cache/@openai")                // scoped package parent
        fs.addDirectory("\(testHome)/Library/Logs/codex")
        let codex = tool("codex", registryID: "codex", installations: [installation("npm:@openai/codex", provider: .npm, package: "@openai/codex")])
        let scanner = LeftoverScanner(fileSystem: fs)
        #expect(scanner.leftovers(for: "codex", in: snapshot([codex])).map(\.path) == ["\(testHome)/Library/Logs/codex"])
        #expect(scanner.rejection(for: "\(testHome)/Library/Caches/codex", origin: .exactName, tool: "codex", in: snapshot([codex])) == .missing)
        #expect(!LeftoverScanner.isExactName("@openai/codex"))
        #expect(!LeftoverScanner.isExactName(".."))
        #expect(!LeftoverScanner.isExactName("x"))
        #expect(!LeftoverScanner.isExactName("cod*"))
    }

    // MARK: Safety rules

    @Test func onlyInsideTheHomeDirectory() {
        let fs = InMemoryFileSystem(home: testHome)
        fs.addDirectory("/opt/homebrew/var/claude")
        fs.addDirectory("/Users/other/.claude")
        let scanner = LeftoverScanner(fileSystem: fs)
        let empty = snapshot([])
        #expect(scanner.rejection(for: "/opt/homebrew/var/claude", tool: "claude-code", in: empty) == .outsideHome)
        #expect(scanner.rejection(for: "/Users/other/.claude", tool: "claude-code", in: empty) == .outsideHome)
        #expect(scanner.rejection(for: "/Users/tester2/.claude", tool: "claude-code", in: empty) == .outsideHome)
        #expect(scanner.rejection(for: "\(testHome)/../other/.claude", tool: "claude-code", in: empty) == .notAbsolute)
        #expect(scanner.rejection(for: ".claude", tool: "claude-code", in: empty) == .notAbsolute)
    }

    @Test func neverTheHomeDirectoryOrSharedContainers() {
        let fs = InMemoryFileSystem(home: testHome)
        for path in ["Library/Caches", "Library/Logs", "Library/Application Support", ".config", ".cache", ".local/state", ".local/share", ".local/bin", "go"] {
            fs.addDirectory("\(testHome)/\(path)")
        }
        let scanner = LeftoverScanner(fileSystem: fs)
        let empty = snapshot([])
        #expect(scanner.rejection(for: testHome, tool: "x", in: empty) == .homeDirectory)
        #expect(scanner.rejection(for: testHome + "/", tool: "x", in: empty) == .homeDirectory)
        for path in ["Library", "Library/Caches", "Library/Logs", "Library/Application Support", ".config", ".cache", ".local", ".local/state", ".local/share", ".local/bin", "go", "Applications"] {
            #expect(scanner.rejection(for: "\(testHome)/\(path)", tool: "x", in: empty) == .protectedLocation, "\(path)")
        }
        for path in ["Library/Keychains/login.keychain-db", ".ssh/id_ed25519", ".gnupg", ".Trash/claude", "Library/Containers/com.x"] {
            #expect(scanner.rejection(for: "\(testHome)/\(path)", tool: "x", in: empty) == .protectedLocation, "\(path)")
        }
    }

    @Test func neverPersonalOrICloudFolders() {
        let fs = InMemoryFileSystem(home: testHome)
        let scanner = LeftoverScanner(fileSystem: fs)
        let empty = snapshot([])
        for path in ["Desktop", "Documents/claude", "Downloads/gh", "Library/Mobile Documents/com~apple~CloudDocs/uv", "Library/CloudStorage/Dropbox/.cache"] {
            #expect(scanner.rejection(for: "\(testHome)/\(path)", tool: "x", in: empty) == .personalFolder, "\(path)")
        }
    }

    @Test func neverShellConfiguration() {
        let fs = InMemoryFileSystem(home: testHome)
        fs.addFile("\(testHome)/.zshrc")
        fs.addDirectory("\(testHome)/.config/fish")
        let scanner = LeftoverScanner(fileSystem: fs)
        let empty = snapshot([])
        for path in [".zshrc", ".bash_profile", ".profile", ".config/fish", ".zsh_history"] {
            #expect(scanner.rejection(for: "\(testHome)/\(path)", tool: "x", in: empty) == .shellConfiguration, "\(path)")
        }
        // A tool named `fish` must not claim `~/.config/fish` through exact names either.
        let fish = tool("fish", installations: [installation("homebrew:fish", provider: .homebrew, package: "fish", prefix: "/opt/homebrew/Cellar/fish/4.0")])
        #expect(!scanner.leftovers(for: "fish", in: snapshot([fish])).contains { $0.path.hasSuffix("/.config/fish") })
    }

    @Test func neverTheInstallationItself() {
        let fs = InMemoryFileSystem(home: testHome)
        fs.addDirectory("\(testHome)/.bun/install/cache")
        fs.addExecutable("\(testHome)/.bun/bin/bun")
        let bun = tool("bun", registryID: "bun", installations: [installation("native:bun", provider: .native, package: "bun", prefix: "\(testHome)/.bun",
                                                                                executables: [ExecutableRef(name: "bun", path: "\(testHome)/.bun/bin/bun")])])
        let scanner = LeftoverScanner(fileSystem: fs)
        let scenario = snapshot([bun])
        #expect(scanner.rejection(for: "\(testHome)/.bun/install/cache", tool: "bun", in: scenario) == .installation)
        #expect(scanner.rejection(for: "\(testHome)/.bun", tool: "bun", in: scenario) == .installation)
        #expect(scanner.rejection(for: "\(testHome)/.bun/bin/bun", tool: "bun", in: scenario) == .installation)
        #expect(scanner.leftovers(for: "bun", in: scenario).isEmpty)
    }

    @Test func neverAnInstallerReceipt() {
        let fs = InMemoryFileSystem(home: testHome)
        fs.addFile("\(testHome)/.config/uv/uv-receipt.json")
        fs.addDirectory("\(testHome)/.cache/uv")
        let scanner = LeftoverScanner(fileSystem: fs)
        // Even with uv not in the snapshot, its receipt keeps identifying the native install.
        #expect(scanner.rejection(for: "\(testHome)/.config/uv", origin: .exactName, tool: "uv", in: snapshot([])) == .installation)
        #expect(scanner.leftovers(for: "uv", in: snapshot([])).map(\.path) == ["\(testHome)/.cache/uv"])
    }

    @Test func neverAnotherInstalledToolsFiles() {
        let fs = InMemoryFileSystem(home: testHome)
        fs.addDirectory("\(testHome)/.local/share/uv/tools/kimi-cli")
        fs.addDirectory("\(testHome)/.cache/uv")
        fs.addDirectory("\(testHome)/.config/gh")
        fs.addDirectory("\(testHome)/.cache/shared-name")
        let uv = tool("uv", registryID: "uv", installations: [installation("native:uv", provider: .native, package: "uv", executables: [ExecutableRef(name: "uv", path: "\(testHome)/.local/bin/uv")])])
        let kimi = tool("kimi-cli", registryID: "kimi-cli", installations: [installation("uv:kimi-cli", provider: .uv, package: "kimi-cli", prefix: "\(testHome)/.local/share/uv/tools/kimi-cli")])
        let gh = tool("gh", registryID: "gh", installations: [installation("homebrew:gh", provider: .homebrew, package: "gh", prefix: "/opt/homebrew/Cellar/gh/2.92.0")])
        let a = tool("npm.a", name: "shared-name", installations: [installation("npm:shared-name", provider: .npm, package: "shared-name")])
        let b = tool("pipx.b", name: "shared-name", installations: [installation("pipx:shared-name", provider: .pipx, package: "shared-name")])
        let scenario = snapshot([uv, kimi, gh, a, b])
        let scanner = LeftoverScanner(fileSystem: fs)

        // Another tool's install prefix, and anything containing it.
        #expect(scanner.rejection(for: "\(testHome)/.local/share/uv/tools/kimi-cli", tool: "uv", in: scenario) == .otherTool("kimi-cli"))
        #expect(scanner.rejection(for: "\(testHome)/.local/share/uv/tools", tool: "uv", in: scenario) == .otherTool("kimi-cli"))
        // Another tool's registry leftovers.
        #expect(scanner.rejection(for: "\(testHome)/.config/gh", origin: .exactName, tool: "kimi-cli", in: scenario) == .otherTool("gh"))
        #expect(scanner.rejection(for: "\(testHome)/.cache/uv", tool: "kimi-cli", in: scenario) == .otherTool("uv"))
        // A name two installed tools share belongs to neither.
        #expect(scanner.leftovers(for: "npm.a", in: scenario).isEmpty)
        #expect(scanner.leftovers(for: "uv", in: scenario).map(\.path) == ["\(testHome)/.cache/uv"])
    }

    @Test func neverAPathDirectoryOrItsAncestors() {
        let fs = InMemoryFileSystem(home: testHome)
        fs.addDirectory("\(testHome)/.mytool/bin")
        let scanner = LeftoverScanner(fileSystem: fs)
        let scenario = snapshot([], pathEntries: ["\(testHome)/.mytool/bin"])
        #expect(scanner.rejection(for: "\(testHome)/.mytool", tool: "mytool", in: scenario) == .pathEntry)
        #expect(scanner.rejection(for: "\(testHome)/.mytool/bin", tool: "mytool", in: scenario) == .pathEntry)
    }

    @Test func symlinksMustNotEscape() {
        let fs = InMemoryFileSystem(home: testHome)
        fs.addDirectory("/Volumes/External/codex")
        fs.addSymlink("\(testHome)/.codex", to: "/Volumes/External/codex")
        fs.addDirectory("\(testHome)/Documents/gemini")
        fs.addSymlink("\(testHome)/.gemini", to: "\(testHome)/Documents/gemini")
        fs.addDirectory("/Volumes/External/cache")
        fs.addSymlink("\(testHome)/.cache", to: "/Volumes/External/cache")
        fs.addDirectory("/Volumes/External/cache/uv")
        fs.addSymlink("\(testHome)/.copilot", to: "\(testHome)/.missing")
        fs.addDirectory("\(testHome)/dotfiles/qwen")
        fs.addSymlink("\(testHome)/.qwen", to: "\(testHome)/dotfiles/qwen")
        fs.addSymlink("\(testHome)/.claude", to: testHome)
        let scanner = LeftoverScanner(fileSystem: fs)
        let empty = snapshot([])
        #expect(scanner.rejection(for: "\(testHome)/.codex", tool: "codex", in: empty) == .outsideHome)
        #expect(scanner.rejection(for: "\(testHome)/.gemini", tool: "gemini-cli", in: empty) == .personalFolder)
        #expect(scanner.rejection(for: "\(testHome)/.cache/uv", tool: "uv", in: empty) == .outsideHome, "an intermediate link counts too")
        #expect(scanner.rejection(for: "\(testHome)/.copilot", tool: "copilot-cli", in: empty) == .unresolvable)
        #expect(scanner.rejection(for: "\(testHome)/.claude", tool: "claude-code", in: empty) == .homeDirectory)
        #expect(scanner.rejection(for: "\(testHome)/.qwen", tool: "qwen-code", in: empty) == nil)
    }

    @Test func symlinkIntoAnotherToolIsRefused() {
        let fs = InMemoryFileSystem(home: testHome)
        fs.addDirectory("\(testHome)/.local/share/claude/versions")
        fs.addSymlink("\(testHome)/.codex", to: "\(testHome)/.local/share/claude")
        let claude = tool("claude-code", registryID: "claude-code", installations: [installation("native:claude-code", provider: .native, prefix: "\(testHome)/.local/share/claude")])
        #expect(LeftoverScanner(fileSystem: fs).rejection(for: "\(testHome)/.codex", tool: "codex", in: snapshot([claude])) == .otherTool("claude-code"))
    }

    @Test func skipsItemsNotOwnedByTheCurrentUser() {
        let fs = InMemoryFileSystem(home: testHome)
        fs.addDirectory("\(testHome)/.codex")
        fs.setOwner("\(testHome)/.codex", uid: 0)
        fs.addDirectory("\(testHome)/rootowned/gemini")
        fs.setOwner("\(testHome)/rootowned/gemini", uid: 0)
        fs.addSymlink("\(testHome)/.gemini", to: "\(testHome)/rootowned/gemini")
        let scanner = LeftoverScanner(fileSystem: fs)
        let empty = snapshot([])
        #expect(scanner.rejection(for: "\(testHome)/.codex", tool: "codex", in: empty) == .notOwnedByUser)
        #expect(scanner.rejection(for: "\(testHome)/.gemini", tool: "gemini-cli", in: empty) == .notOwnedByUser, "the link target's owner counts")

        let unknownUser = InMemoryFileSystem(home: testHome, currentUserID: nil)
        unknownUser.addDirectory("\(testHome)/.codex")
        #expect(LeftoverScanner(fileSystem: unknownUser).leftovers(for: "codex", in: empty).isEmpty, "unknown ownership fails closed")
    }

    // MARK: Size

    @Test func sizeWalkIsBoundedAndDoesNotFollowLinks() throws {
        let fs = InMemoryFileSystem(home: testHome)
        for index in 0..<30 {
            fs.addFile("\(testHome)/.npm/_cacache/content/\(index)", contents: Data(repeating: 0, count: 10))
        }
        fs.addDirectory("/Volumes/Big")
        fs.addFile("/Volumes/Big/huge", contents: Data(repeating: 0, count: 5000))
        fs.addSymlink("\(testHome)/.codex/link", to: "/Volumes/Big")
        fs.addFile("\(testHome)/.codex/config.toml", contents: Data(repeating: 0, count: 7))

        let bounded = LeftoverScanner(fileSystem: fs, entryLimit: 10).leftovers(for: "npm", in: snapshot([]))
        let cache = try #require(bounded.first { $0.path == "\(testHome)/.npm/_cacache" })
        #expect(cache.sizeIsLowerBound)
        #expect(cache.sizeBytes < 300)

        let full = LeftoverScanner(fileSystem: fs).leftovers(for: "npm", in: snapshot([]))
        #expect(full.first?.sizeBytes == 300 && full.first?.sizeIsLowerBound == false)

        let codex = LeftoverScanner(fileSystem: fs).leftovers(for: "codex", in: snapshot([]))
        #expect(codex.first?.sizeBytes == 7)
    }
}
