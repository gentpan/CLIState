import CLIStateDomain
import Foundation

/// A realistic snapshot modeled on a developer Mac scan (home redacted to
/// `/Users/tester`). Used by `PreviewActions` and SwiftUI previews.
enum SampleSnapshot {
    static let home = "/Users/tester"
    static let brew = "/opt/homebrew/bin/brew"
    static let npmRoot: ProviderInstanceID = "npm@/opt/homebrew/lib/node_modules"
    static let homebrewEnv = ["HOMEBREW_NO_AUTO_UPDATE": "1"]

    // MARK: Snapshot

    static func make(now: Date = .now) -> EnvironmentSnapshot {
        let scannedAt = now.addingTimeInterval(-3 * 60)
        let pathEntries = self.pathEntries()
        let brokenSymlinks = self.brokenSymlinks()
        let tools = self.tools(at: scannedAt)
        var snapshot = EnvironmentSnapshot(
            capturedAt: scannedAt,
            depth: .fast,
            shell: ShellEnvironment(
                shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh),
                path: pathEntries.map(\.rawValue),
                variables: [
                    "HOME": home,
                    "SHELL": "/bin/zsh",
                    "HOMEBREW_PREFIX": "/opt/homebrew",
                    "HOMEBREW_CELLAR": "/opt/homebrew/Cellar",
                    "LANG": "en_US.UTF-8",
                ],
                source: .loginShell,
                capturedAt: scannedAt
            ),
            pathEntries: pathEntries,
            brokenSymlinks: brokenSymlinks,
            providers: providers(at: scannedAt, tools: tools),
            tools: tools,
            services: tools.compactMap(\.service),
            issues: issues(brokenSymlinks: brokenSymlinks),
            cleanupCandidates: cleanupCandidates(brokenSymlinks: brokenSymlinks)
        )
        SampleEndOfLife.apply(to: &snapshot, now: now)
        return snapshot
    }

    // MARK: PATH

    static func pathEntries() -> [PATHEntry] {
        let cryptex = "/var/run/com.apple.security.cryptexd/codex.system/bootstrap"
        let rows: [(String, PATHEntryStatus, PATHSource, Bool, Int, Int?)] = [
            ("\(home)/Library/Application Support/Herd/bin/", .missing, .application, false, 0, nil),
            ("\(home)/.codeium/windsurf/bin", .ok, .application, true, 1, nil),
            ("\(home)/.bun/bin", .ok, .bun, true, 2, nil),
            ("\(home)/.cargo/bin", .ok, .cargo, true, 14, nil),
            ("\(home)/go/bin", .ok, .go, true, 3, nil),
            ("\(home)/.mavis/bin", .ok, .unknown, true, 1, nil),
            ("\(home)/.lmstudio/bin", .ok, .application, true, 1, nil),
            ("\(home)/.antigravity/antigravity/bin", .ok, .application, true, 2, nil),
            ("\(home)/.mavis/bin", .duplicate, .unknown, true, 0, 6),
            ("\(home)/.local/bin", .ok, .userLocal, true, 9, nil),
            ("/opt/homebrew/bin", .ok, .homebrew, true, 719, nil),
            ("/opt/homebrew/sbin", .ok, .homebrew, true, 12, nil),
            ("/usr/local/bin", .ok, .userLocal, false, 6, nil),
            ("/System/Cryptexes/App/usr/bin", .ok, .system, false, 3, nil),
            ("/usr/bin", .ok, .system, false, 932, nil),
            ("/bin", .ok, .system, false, 36, nil),
            ("/usr/sbin", .ok, .system, false, 88, nil),
            ("/sbin", .ok, .system, false, 13, nil),
            ("\(cryptex)/usr/local/bin", .missing, .system, false, 0, nil),
            ("\(cryptex)/usr/bin", .missing, .system, false, 0, nil),
            ("\(cryptex)/usr/appleinternal/bin", .missing, .system, false, 0, nil),
            ("/pkg/env/global/bin", .missing, .unknown, false, 0, nil),
            ("/Library/Apple/usr/bin", .ok, .system, false, 5, nil),
        ]
        return rows.enumerated().map { index, row in
            let normalized = row.0.hasSuffix("/") ? String(row.0.dropLast()) : row.0
            return PATHEntry(priority: index + 1, rawValue: row.0, normalizedPath: normalized, status: row.1, source: row.2, isWritable: row.3, executableCount: row.4, duplicateOf: row.5)
        }
    }

    static func brokenSymlinks() -> [BrokenSymlink] {
        let python312 = ["2to3-3.12", "idle3.12", "pip3.12", "pydoc3.12", "python3.12", "python3.12-config", "wheel3.12"]
        return [BrokenSymlink(path: "/opt/homebrew/bin/codexbar", destination: "../Caskroom/codexbar/0.9.1/CodexBar.app/Contents/Resources/codexbar", pathPriority: 11)]
            + python312.map { BrokenSymlink(path: "/opt/homebrew/bin/\($0)", destination: "../Cellar/python@3.12/3.12.9/bin/\($0)", pathPriority: 11) }
            + [
                BrokenSymlink(path: "/opt/homebrew/bin/corepack", destination: "../lib/node_modules/corepack/dist/corepack.js", pathPriority: 11),
                BrokenSymlink(path: "/opt/homebrew/bin/php-config8.3", destination: "../Cellar/php@8.3/8.3.20/bin/php-config", pathPriority: 11),
                BrokenSymlink(path: "/usr/local/bin/docker-credential-desktop", destination: "/Applications/Docker.app/Contents/Resources/bin/docker-credential-desktop", pathPriority: 13),
                BrokenSymlink(path: "/usr/local/bin/docker-compose", destination: "/Applications/Docker.app/Contents/Resources/cli-plugins/docker-compose", pathPriority: 13),
                BrokenSymlink(path: "/usr/local/bin/kubectl.docker", destination: "/Applications/Docker.app/Contents/Resources/bin/kubectl", pathPriority: 13),
                BrokenSymlink(path: "\(home)/.local/bin/aider", destination: "\(home)/.local/share/uv/tools/aider-chat/bin/aider", pathPriority: 10),
            ]
    }

    // MARK: Tools

    static func tools(at date: Date) -> [Tool] {
        let at = date
        var tools: [Tool] = []

        // Node.js: standalone binary in ~/.local/bin shadows Homebrew.
        let nodeStandalone = ToolInstallation(
            id: .path("\(home)/.local/bin/node"),
            ownership: Ownership(provider: .standalone, confidence: .unknown, evidence: [.pathDirectory("\(home)/.local/bin")]),
            version: observed("26.2.0", .executable("\(home)/.local/bin/node"), .confirmed, at),
            executables: [ExecutableRef(name: "node", path: "\(home)/.local/bin/node", pathPriority: 10, architecture: .arm64)],
            linkState: .active,
            capabilities: ToolCapabilities(canMoveToTrash: true)
        )
        let nodeBrew = brewInstallation("node", version: "26.7.0", latest: "26.8.2", commands: ["node", "npx"], linkState: .shadowed, dependencies: ["brotli", "c-ares", "icu4c@77", "libnghttp2", "libuv", "openssl@3"], at: at)
        tools.append(tool(
            "node", name: "node", display: "Node.js",
            summary: "JavaScript runtime built on V8",
            category: .runtime, installations: [nodeStandalone, nodeBrew], active: nodeStandalone.id,
            command: "node", health: .pathConflict, issueIDs: ["pathConflict:node"], homepage: "https://nodejs.org", at: at
        ))

        // PHP plus a keg-only php@8.2 that isn't on PATH.
        let php = brewInstallation("php", version: "8.5.7", latest: "8.5.10", commands: ["php", "phpize", "php-config"], linkState: .active,
                                   dependencies: ["apr-util", "aom", "curl", "dav1d", "fontconfig", "freetds", "libpq", "libssh2", "openldap"],
                                   dependents: ["composer"],
                                   configPaths: ["/opt/homebrew/etc/php/8.5/php.ini", "/opt/homebrew/etc/php/8.5/php-fpm.d"], at: at)
        let php82 = ToolInstallation(
            id: .package(provider: .homebrew, name: "php@8.2"),
            ownership: Ownership(provider: .homebrew, packageName: "php@8.2", confidence: .confirmed, evidence: [.inventoryContains(provider: .homebrew, package: "php@8.2"), .knownLayout("/opt/homebrew/opt/php@8.2")]),
            version: observed("8.2.29", .provider(.homebrew), .confirmed, at),
            latest: observed("8.2.29", .provider(.homebrew), .confirmed, at),
            executables: [ExecutableRef(name: "php", path: "/opt/homebrew/opt/php@8.2/bin/php", resolvedPath: "/opt/homebrew/Cellar/php@8.2/8.2.29/bin/php", architecture: .arm64)],
            installPrefix: "/opt/homebrew/Cellar/php@8.2/8.2.29",
            linkState: .notOnPath,
            isDirect: true,
            capabilities: ToolCapabilities(canUpdate: true, canUninstall: true),
            configPaths: ["/opt/homebrew/etc/php/8.2/php.ini"]
        )
        tools.append(tool("php", name: "php", display: "PHP", summary: "General-purpose scripting language", category: .runtime,
                          installations: [php, php82], active: php.id, command: "php", health: .updateAvailable, homepage: "https://www.php.net", at: at))

        tools.append(tool("composer", name: "composer", display: "Composer", summary: "Dependency manager for PHP", category: .packageManager,
                          installations: [brewInstallation("composer", version: "2.9.8", latest: "2.10.3", commands: ["composer"], linkState: .active, architecture: .script, dependencies: ["php"], at: at)],
                          command: "composer", health: .updateAvailable, homepage: "https://getcomposer.org", at: at))

        tools.append(tool("go", name: "go", display: "Go", summary: "Open source programming language", category: .runtime,
                          installations: [brewInstallation("go", version: "1.27.1", latest: "1.27.1", commands: ["go", "gofmt"], linkState: .active, resolvedDirectory: "libexec/bin", at: at)],
                          command: "go", health: .healthy, homepage: "https://go.dev", at: at))

        // Python: Homebrew 3.14 active, the Xcode shim in /usr/bin shadowed.
        let pythonBrew = brewInstallation("python@3.14", version: "3.14.7", latest: "3.14.7", commands: ["python3", "pip3"], linkState: .active,
                                          resolvedDirectory: "Frameworks/Python.framework/Versions/3.14/bin", dependencies: ["mpdecimal", "openssl@3", "sqlite", "xz"], at: at)
        let pythonSystem = systemInstallation("python3", version: "3.9.6", linkState: .shadowed, at: at)
        tools.append(tool("python", name: "python3", display: "Python", summary: "Interpreted, interactive, object-oriented programming language", category: .runtime,
                          installations: [pythonBrew, pythonSystem], active: pythonBrew.id, command: "python3", health: .healthy, homepage: "https://www.python.org", at: at))

        tools.append(tool("rust", name: "rustc", display: "Rust", summary: "Safe, concurrent, practical language", category: .runtime,
                          installations: [brewInstallation("rust", version: "1.95.0", latest: "1.98.1", commands: ["rustc", "cargo", "rustdoc"], linkState: .active, at: at)],
                          command: "rustc", health: .updateAvailable, homepage: "https://www.rust-lang.org", at: at))

        tools.append(tool("ffmpeg", name: "ffmpeg", display: "FFmpeg", summary: "Play, record, convert, and stream audio and video", category: .developerTool,
                          installations: [brewInstallation("ffmpeg", version: "8.1.2_1", latest: "9.0.1", commands: ["ffmpeg", "ffprobe"], linkState: .active, dependencies: ["aom", "dav1d", "lame", "libvpx", "x264", "x265"], at: at)],
                          command: "ffmpeg", health: .updateAvailable, homepage: "https://ffmpeg.org", at: at))

        tools.append(tool("gh", name: "gh", display: "GitHub CLI", summary: "GitHub command-line tool", category: .developerTool,
                          installations: [brewInstallation("gh", version: "2.92.0", latest: "2.100.0", commands: ["gh"], linkState: .active, configPaths: ["\(home)/.config/gh"], at: at)],
                          command: "gh", health: .updateAvailable, homepage: "https://cli.github.com", at: at))

        // Services.
        var postgres = brewInstallation("postgresql@17", version: "17.10", latest: "17.11", commands: ["psql", "pg_ctl", "postgres"], linkState: .active, dependencies: ["icu4c@77", "krb5", "lz4", "openssl@3", "readline", "zstd"], configPaths: ["/opt/homebrew/var/postgresql@17/postgresql.conf"], at: at)
        postgres.capabilities.canStop = true
        postgres.capabilities.canRestart = true
        let postgresService = ToolService(id: "homebrew:postgresql@17", name: "postgresql@17", providerID: .homebrew, status: .running, rawStatus: "started", toolID: "postgresql", installationID: postgres.id, user: "tester", plistPath: "\(home)/Library/LaunchAgents/homebrew.mxcl.postgresql@17.plist", exitCode: 0)
        tools.append(tool("postgresql", name: "psql", display: "PostgreSQL 17", summary: "Object-relational database system", category: .database,
                          installations: [postgres], command: "psql", service: postgresService, health: .updateAvailable, homepage: "https://www.postgresql.org", at: at))

        var caddy = brewInstallation("caddy", version: "2.10.2", latest: "2.10.2", commands: ["caddy"], linkState: .active, configPaths: ["/opt/homebrew/etc/Caddyfile"], at: at)
        caddy.capabilities.canStart = true
        let caddyService = ToolService(id: "homebrew:caddy", name: "caddy", providerID: .homebrew, status: .stopped, rawStatus: "none", toolID: "caddy", installationID: caddy.id)
        tools.append(tool("caddy", name: "caddy", display: "Caddy", summary: "Web server with automatic HTTPS", category: .developerTool,
                          installations: [caddy], command: "caddy", service: caddyService, health: .healthy, homepage: "https://caddyserver.com", at: at))

        // AI CLI.
        let claude = ToolInstallation(
            id: "native:claude-code",
            ownership: Ownership(provider: .native, packageName: "claude-code", confidence: .confirmed, evidence: [.knownLayout("\(home)/.local/share/claude/versions/"), .versionMatches("2.1.234")]),
            version: observed("2.1.234", .executable("\(home)/.local/bin/claude"), .confirmed, at),
            latest: observed("2.1.270", .updateSource("npm-dist-tags:@anthropic-ai/claude-code"), .confirmed, at),
            latestChannel: "latest",
            executables: [ExecutableRef(name: "claude", path: "\(home)/.local/bin/claude", resolvedPath: "\(home)/.local/share/claude/versions/2.1.234", pathPriority: 10, architecture: .arm64)],
            installPrefix: "\(home)/.local/share/claude",
            linkState: .active,
            isDirect: true,
            capabilities: ToolCapabilities(canUpdate: true),
            configPaths: ["\(home)/.claude", "\(home)/.claude.json"]
        )
        tools.append(tool("claude-code", name: "claude", display: "Claude Code", summary: "Agentic coding tool that lives in your terminal", category: .aiCLI,
                          installations: [claude], command: "claude", health: .updateAvailable, homepage: "https://claude.com/claude-code", at: at))

        let kimi = ToolInstallation(
            id: .package(provider: .uv, name: "kimi-cli"),
            ownership: Ownership(provider: .uv, packageName: "kimi-cli", confidence: .confirmed, evidence: [.inventoryContains(provider: .uv, package: "kimi-cli"), .symlinkResolvesInto("\(home)/.local/share/uv/tools/kimi-cli")]),
            version: observed("1.49.0", .provider(.uv), .confirmed, at),
            latest: observed("1.50.0", .provider(.uv), .confirmed, at),
            executables: [ExecutableRef(name: "kimi", path: "\(home)/.local/bin/kimi", resolvedPath: "\(home)/.local/share/uv/tools/kimi-cli/bin/kimi", pathPriority: 10, architecture: .script)],
            installPrefix: "\(home)/.local/share/uv/tools/kimi-cli",
            linkState: .active,
            isDirect: true,
            capabilities: ToolCapabilities(canUpdate: true, canUninstall: true),
            configPaths: ["\(home)/.kimi"]
        )
        tools.append(tool("kimi-cli", name: "kimi", display: "Kimi CLI", summary: "Kimi coding agent for the terminal", category: .aiCLI,
                          installations: [kimi], command: "kimi", health: .updateAvailable, at: at))

        // Package managers.
        tools.append(tool("npm", name: "npm", display: "npm", summary: "Package manager for JavaScript", category: .packageManager,
                          installations: [npmInstallation("npm", version: "12.0.1", latest: "12.0.2", commands: ["npm", "npx"], entry: "bin/npm-cli.js", at: at)],
                          command: "npm", health: .updateAvailable, homepage: "https://www.npmjs.com", at: at))
        tools.append(tool("pnpm", name: "pnpm", display: "pnpm", summary: "Fast, disk space efficient package manager", category: .packageManager,
                          installations: [npmInstallation("pnpm", version: "10.33.0", latest: "12.4.1", commands: ["pnpm", "pnpx"], entry: "bin/pnpm.cjs", at: at)],
                          command: "pnpm", health: .updateAvailable, homepage: "https://pnpm.io", at: at))

        let uv = ToolInstallation(
            id: "native:uv",
            ownership: Ownership(provider: .native, packageName: "uv", confidence: .confirmed, evidence: [.knownLayout("\(home)/.config/uv/uv-receipt.json"), .versionMatches("0.11.8")]),
            version: observed("0.11.8", .executable("\(home)/.local/bin/uv"), .confirmed, at),
            executables: [
                ExecutableRef(name: "uv", path: "\(home)/.local/bin/uv", pathPriority: 10, architecture: .arm64),
                ExecutableRef(name: "uvx", path: "\(home)/.local/bin/uvx", pathPriority: 10, architecture: .arm64),
            ],
            linkState: .active,
            isDirect: true,
            capabilities: ToolCapabilities(canUpdate: true),
            configPaths: ["\(home)/.config/uv"]
        )
        tools.append(tool("uv", name: "uv", display: "uv", summary: "Extremely fast Python package and project manager", category: .packageManager,
                          installations: [uv], command: "uv", health: .healthy, homepage: "https://docs.astral.sh/uv", at: at))

        // The same unregistered package installed globally by both npm and Bun:
        // two tools with one display name, told apart by provider in lists.
        let opencodePackage = "@opencode-ai/cli"
        var opencodeNPM = npmInstallation(opencodePackage, version: "0.4.2", latest: "0.5.0", commands: ["opencode2"], entry: "bin/opencode2", at: at)
        opencodeNPM.linkState = .shadowed
        let opencodeBunRoot = "\(home)/.bun/install/global/node_modules/\(opencodePackage)"
        let opencodeBun = ToolInstallation(
            id: .package(provider: .bun, name: opencodePackage),
            ownership: Ownership(provider: .bun, packageName: opencodePackage, confidence: .probable, evidence: [.symlinkResolvesInto(opencodeBunRoot)]),
            version: observed("0.5.0", .executable("\(home)/.bun/bin/opencode2"), .probable, at),
            executables: [ExecutableRef(name: "opencode2", path: "\(home)/.bun/bin/opencode2", resolvedPath: "\(opencodeBunRoot)/bin/opencode2", pathPriority: 3, architecture: .script)],
            installPrefix: opencodeBunRoot,
            linkState: .active,
            isDirect: true
        )
        tools.append(tool("npm.\(opencodePackage)", name: opencodePackage, display: opencodePackage, category: .developerTool,
                          installations: [opencodeNPM], command: "opencode2", health: .updateAvailable, at: at))
        tools.append(tool("bun.\(opencodePackage)", name: opencodePackage, display: opencodePackage, category: .developerTool,
                          installations: [opencodeBun], command: "opencode2", health: .healthy, at: at))

        tools.append(tool("git", name: "git", display: "Git", summary: "Distributed revision control system", category: .developerTool,
                          installations: [systemInstallation("git", version: "2.54.0", linkState: .active, at: at)],
                          command: "git", health: .healthy, homepage: "https://git-scm.com", at: at))

        // Dependencies (hidden unless Settings ▸ Scanning ▸ Show dependencies).
        for (formula, from, to, keg) in [("libpq", "18.4", "18.6", true), ("openldap", "2.6.13", "2.7.1", true), ("aom", "3.14.1", "3.15.0", false)] {
            var installation = brewInstallation(formula, version: from, latest: to, commands: keg ? [] : ["aomenc", "aomdec"], linkState: keg ? .notOnPath : .active, isDirect: false, dependents: ["php"], at: at)
            installation.capabilities.canUninstall = false
            tools.append(tool("homebrew.\(formula)", name: formula, display: formula, category: .dependency,
                              installations: [installation], command: keg ? nil : "aomenc", health: .updateAvailable, at: at))
        }

        // Unrecognized executable.
        let mavis = ToolInstallation(
            id: .path("\(home)/.mavis/bin/mavis"),
            ownership: Ownership(provider: .standalone, confidence: .unknown, evidence: [.pathDirectory("\(home)/.mavis/bin")]),
            executables: [ExecutableRef(name: "mavis", path: "\(home)/.mavis/bin/mavis", pathPriority: 6, architecture: .arm64)],
            linkState: .active,
            capabilities: ToolCapabilities(canMoveToTrash: true)
        )
        tools.append(tool("unknown.4f1c9a", name: "mavis", display: "mavis", category: .unrecognized,
                          installations: [mavis], command: "mavis", health: .unknown, at: at))

        applyUsage(to: &tools, at: at)
        return tools
    }

    // MARK: Usage

    /// Disk usage and last use as a deep scan measures them on the developer Mac: hundreds
    /// of MB for runtimes and databases, tens for smaller tools; some used minutes ago,
    /// some weeks ago, and none for system tools, keg-only formulae and unused leftovers.
    static func applyUsage(to tools: inout [Tool], at date: Date) {
        let minute: TimeInterval = 60
        let hour = 60 * minute
        let day = 24 * hour
        let megabyte: Int64 = 1_000_000
        // (megabytes, time since the last use; nil when never used or unknown)
        let usage: [InstallationID: (megabytes: Double, lastUsed: TimeInterval?)] = [
            .path("\(home)/.local/bin/node"): (118.4, 20 * minute),
            .package(provider: .homebrew, name: "node"): (212.6, 9 * day),
            .package(provider: .homebrew, name: "php"): (96.3, 3 * day),
            .package(provider: .homebrew, name: "php@8.2"): (118.0, nil),
            .package(provider: .homebrew, name: "composer"): (3.1, 3 * day + 2 * hour),
            .package(provider: .homebrew, name: "go"): (243.5, 2 * hour),
            .package(provider: .homebrew, name: "python@3.14"): (286.2, 40 * minute),
            .package(provider: .homebrew, name: "rust"): (371.0, 16 * day),
            .package(provider: .homebrew, name: "ffmpeg"): (54.8, 4 * day),
            .package(provider: .homebrew, name: "gh"): (43.2, 8 * minute),
            .package(provider: .homebrew, name: "postgresql@17"): (341.7, 1 * day + 5 * hour),
            .package(provider: .homebrew, name: "caddy"): (45.9, 41 * day),
            "native:claude-code": (310.7, 2 * minute),
            .package(provider: .uv, name: "kimi-cli"): (220.1, 35 * day),
            .package(provider: .npm, instance: npmRoot, name: "npm"): (11.8, 1 * hour),
            .package(provider: .npm, instance: npmRoot, name: "pnpm"): (17.4, 23 * day),
            "native:uv": (41.3, 5 * hour),
            .package(provider: .npm, instance: npmRoot, name: "@opencode-ai/cli"): (28.5, nil),
            .package(provider: .bun, name: "@opencode-ai/cli"): (31.2, 12 * day),
            .package(provider: .homebrew, name: "libpq"): (12.4, nil),
            .package(provider: .homebrew, name: "openldap"): (9.1, nil),
            .package(provider: .homebrew, name: "aom"): (8.6, 58 * day),
            .path("\(home)/.mavis/bin/mavis"): (62.0, nil),
        ]
        for toolIndex in tools.indices {
            for index in tools[toolIndex].installations.indices {
                let installation = tools[toolIndex].installations[index]
                guard let entry = usage[installation.id] else { continue }
                tools[toolIndex].installations[index].diskUsage = DiskUsage(
                    bytes: Int64(entry.megabytes * Double(megabyte)),
                    measuredAt: date.addingTimeInterval(-2 * hour),
                    version: installation.version?.value.rawValue
                )
                tools[toolIndex].installations[index].lastUsedAt = entry.lastUsed.map { date.addingTimeInterval(-$0) }
            }
        }
    }

    // MARK: Providers

    static func providers(at date: Date, tools: [Tool]) -> [ProviderSnapshot] {
        func count(_ provider: ProviderID) -> Int {
            tools.filter { $0.installations.contains { $0.ownership.provider == provider } }.count
        }
        return [
            ProviderSnapshot(
                providerID: .homebrew,
                availability: ProviderAvailability(providerID: .homebrew, isAvailable: true, executable: brew, version: "5.1.4"),
                layout: ProviderLayout(roots: [.homebrewPrefix: "/opt/homebrew", .homebrewCellar: "/opt/homebrew/Cellar", .homebrewCaskroom: "/opt/homebrew/Caskroom"]),
                freshness: .fresh(date),
                toolCount: count(.homebrew),
                serviceCount: 2,
                latestCheckedAt: date.addingTimeInterval(-2 * 3600 - 14 * 60),
                warnings: []
            ),
            ProviderSnapshot(
                providerID: .npm,
                availability: ProviderAvailability(providerID: .npm, isAvailable: true, executable: "/opt/homebrew/bin/npm", version: "12.0.1"),
                instance: ProviderInstance(id: npmRoot, providerID: .npm, executable: "/opt/homebrew/bin/npm", version: "12.0.1", context: .homebrew),
                layout: ProviderLayout(roots: [.npmGlobalRoot: "/opt/homebrew/lib/node_modules", .npmGlobalBin: "/opt/homebrew/bin"]),
                freshness: .fresh(date),
                toolCount: count(.npm),
                latestCheckedAt: date.addingTimeInterval(-2 * 3600)
            ),
            ProviderSnapshot(
                providerID: .uv,
                availability: ProviderAvailability(providerID: .uv, isAvailable: true, executable: "\(home)/.local/bin/uv", version: "0.11.8"),
                layout: ProviderLayout(roots: [.uvToolDir: "\(home)/.local/share/uv/tools", .uvToolBinDir: "\(home)/.local/bin"]),
                freshness: .fresh(date),
                toolCount: count(.uv),
                latestCheckedAt: date.addingTimeInterval(-2 * 3600)
            ),
        ]
    }

    // MARK: Issues

    static func issues(brokenSymlinks: [BrokenSymlink]) -> [HealthIssue] {
        [
            HealthIssue(
                type: .pathConflict, severity: .warning, subject: "node", toolID: "node",
                installationIDs: [.path("\(home)/.local/bin/node"), .package(provider: .homebrew, name: "node")],
                paths: ["\(home)/.local/bin/node", "/opt/homebrew/bin/node"],
                suggestedAction: .openPathSettings
            ),
            HealthIssue(
                type: .missingPathEntry, severity: .warning, subject: "\(home)/Library/Application Support/Herd/bin/",
                paths: ["\(home)/Library/Application Support/Herd/bin/"], details: ["priority": "1"],
                suggestedAction: .openPathSettings
            ),
            HealthIssue(
                type: .missingPathEntry, severity: .warning, subject: "/pkg/env/global/bin",
                paths: ["/pkg/env/global/bin"], details: ["priority": "22"],
                suggestedAction: .openPathSettings
            ),
            // One issue per dangling link, matching what the engine reports.
        ] + brokenSymlinks.map { link in
            HealthIssue(
                type: .brokenSymlink, severity: .warning, subject: link.path,
                paths: [link.path, link.absoluteDestination],
                suggestedAction: .revealInFinder(link.path)
            )
        } + [

            HealthIssue(
                type: .duplicatePathEntry, severity: .info, subject: "\(home)/.mavis/bin",
                paths: ["\(home)/.mavis/bin"], details: ["priority": "9", "duplicateOf": "6"],
                suggestedAction: .openPathSettings
            ),
        ]
    }

    // MARK: Cleanup

    static func cleanupCandidates(brokenSymlinks: [BrokenSymlink]) -> [CleanupCandidate] {
        [
            CleanupCandidate(
                kind: .oldVersions, providerID: .homebrew, risk: .low,
                items: [
                    PreflightItem(name: "node", change: .reclaim, fromVersion: "26.6.1"),
                    PreflightItem(name: "php", change: .reclaim, fromVersion: "8.5.6"),
                    PreflightItem(name: "python@3.14", change: .reclaim, fromVersion: "3.14.6"),
                    PreflightItem(name: "go", change: .reclaim, fromVersion: "1.27.0"),
                    PreflightItem(name: "llvm", change: .reclaim, fromVersion: "21.1.8"),
                    PreflightItem(name: "Homebrew download cache", change: .reclaim),
                ],
                paths: ["\(home)/Library/Caches/Homebrew"],
                reclaimableBytes: 1_236_000_000,
                plan: OperationPlan(kind: .cleanup(.oldVersions), providerID: .homebrew, targets: [OperationTarget(packageName: "homebrew", displayName: "Homebrew")],
                                    commands: [Command(executable: brew, arguments: ["cleanup"], environmentOverrides: homebrewEnv)], requiresNetwork: false)
            ),
            CleanupCandidate(
                kind: .orphanedDependencies, providerID: .homebrew, risk: .medium,
                items: [
                    PreflightItem(name: "icu4c@76", change: .remove, fromVersion: "76.1_2"),
                    PreflightItem(name: "libyaml", change: .remove, fromVersion: "0.2.5"),
                    PreflightItem(name: "m4", change: .remove, fromVersion: "1.4.20"),
                    PreflightItem(name: "pkgconf", change: .remove, fromVersion: "2.5.1"),
                ],
                reclaimableBytes: 96_400_000,
                plan: OperationPlan(kind: .cleanup(.orphanedDependencies), providerID: .homebrew, targets: [OperationTarget(packageName: "homebrew", displayName: "Homebrew")],
                                    commands: [Command(executable: brew, arguments: ["autoremove"], environmentOverrides: homebrewEnv)], requiresNetwork: false)
            ),
            CleanupCandidate(
                kind: .providerCache, providerID: .npm, risk: .low,
                paths: ["\(home)/.npm/_cacache"],
                reclaimableBytes: 310_000_000,
                plan: OperationPlan(kind: .cleanup(.providerCache), providerID: .npm, targets: [OperationTarget(packageName: "npm", displayName: "npm")],
                                    commands: [Command(executable: "/opt/homebrew/bin/npm", arguments: ["cache", "clean", "--force"])], requiresNetwork: false)
            ),
            CleanupCandidate(
                kind: .brokenSymlink, providerID: nil, risk: .low,
                paths: brokenSymlinks.map(\.path),
                plan: OperationPlan(kind: .cleanup(.brokenSymlink), providerID: .standalone,
                                    targets: brokenSymlinks.map { OperationTarget(packageName: $0.path, displayName: ($0.path as NSString).lastPathComponent) },
                                    steps: brokenSymlinks.map { .moveToTrash(path: $0.path) }, requiresNetwork: false, mutationScope: "trash"),
                subject: "path"
            ),
            CleanupCandidate(
                kind: .unusedRuntime, providerID: .homebrew, risk: .medium,
                items: [PreflightItem(name: "php@8.2", change: .remove, fromVersion: "8.2.29")],
                paths: ["/opt/homebrew/Cellar/php@8.2/8.2.29"],
                reclaimableBytes: 118_000_000,
                plan: nil,
                subject: "php@8.2"
            ),
        ]
    }

    // MARK: Preflight

    /// `brew upgrade --dry-run php` as observed on the developer Mac.
    static func phpUpdatePreflight() -> [PreflightCheck] {
        [
            PreflightCheck(kind: .providerAvailable, outcome: .passed, detail: "\(brew) 5.1.4"),
            PreflightCheck(kind: .ownershipConfirmed, outcome: .passed, detail: "homebrew:php"),
            PreflightCheck(kind: .writableLocation, outcome: .passed, detail: "/opt/homebrew/Cellar"),
            PreflightCheck(kind: .networkRequired, outcome: .info),
            PreflightCheck(kind: .dryRun, outcome: .warning, detail: "brew upgrade --dry-run php", items: [
                PreflightItem(name: "libpsl", change: .install, toVersion: "0.23.3"),
                PreflightItem(name: "apr-util", change: .upgrade, fromVersion: "1.6.3_1", toVersion: "1.6.5"),
                PreflightItem(name: "libssh2", change: .upgrade, fromVersion: "1.11.1_1", toVersion: "1.11.1_4"),
                PreflightItem(name: "curl", change: .upgrade, fromVersion: "8.20.0", toVersion: "8.22.0"),
                PreflightItem(name: "freetds", change: .upgrade, fromVersion: "1.5.18", toVersion: "1.5.19"),
                PreflightItem(name: "fontconfig", change: .upgrade, fromVersion: "2.18.2", toVersion: "2.18.3"),
                PreflightItem(name: "aom", change: .upgrade, fromVersion: "3.14.1", toVersion: "3.15.0"),
                PreflightItem(name: "dav1d", change: .upgrade, fromVersion: "1.5.3", toVersion: "1.5.4"),
                PreflightItem(name: "libpq", change: .upgrade, fromVersion: "18.4", toVersion: "18.6"),
                PreflightItem(name: "openldap", change: .upgrade, fromVersion: "2.6.13", toVersion: "2.7.1"),
                PreflightItem(name: "composer", change: .upgradeDependent, fromVersion: "2.9.8", toVersion: "2.10.3"),
            ]),
        ]
    }

    // MARK: History

    static func history(now: Date = .now) -> [CommandHistoryEntry] {
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        return [
            CommandHistoryEntry(
                planKind: .service(.restart), providerID: .homebrew,
                commands: ["brew services restart postgresql@17"],
                targets: [OperationTarget(toolID: "postgresql", packageName: "postgresql@17", displayName: "PostgreSQL 17")],
                status: .succeeded, exitCode: 0, startedAt: ago(5), finishedAt: ago(5).addingTimeInterval(4)
            ),
            CommandHistoryEntry(
                planKind: .selfUpdate, trigger: .automaticPolicy, providerID: .native,
                commands: ["claude update"],
                targets: [OperationTarget(toolID: "claude-code", installationID: "native:claude-code", packageName: "claude-code", displayName: "Claude Code", fromVersion: "2.1.230", toVersion: "2.1.234")],
                verifiedVersions: ["native:claude-code": "2.1.234"],
                status: .succeeded, exitCode: 0, startedAt: ago(26), finishedAt: ago(26).addingTimeInterval(38)
            ),
            CommandHistoryEntry(
                planKind: .update, providerID: .homebrew,
                commands: ["brew upgrade ffmpeg"],
                targets: [OperationTarget(toolID: "ffmpeg", installationID: "homebrew:ffmpeg", packageName: "ffmpeg", displayName: "FFmpeg", fromVersion: "8.1.2_1", toVersion: "9.0.1")],
                status: .failed, exitCode: 1, startedAt: ago(30), finishedAt: ago(30).addingTimeInterval(71)
            ),
            CommandHistoryEntry(
                planKind: .update, providerID: .homebrew,
                commands: ["brew upgrade php"],
                targets: [OperationTarget(toolID: "php", installationID: "homebrew:php", packageName: "php", displayName: "PHP", fromVersion: "8.5.6", toVersion: "8.5.7")],
                verifiedVersions: ["homebrew:php": "8.5.7", "homebrew:composer": "2.10.3"],
                status: .succeeded, exitCode: 0, startedAt: ago(40), finishedAt: ago(40).addingTimeInterval(95)
            ),
            CommandHistoryEntry(
                planKind: .update, providerID: .homebrew,
                commands: ["brew upgrade gh"],
                targets: [OperationTarget(toolID: "gh", installationID: "homebrew:gh", packageName: "gh", displayName: "GitHub CLI", fromVersion: "2.91.0", toVersion: "2.92.0")],
                verifiedVersions: ["homebrew:gh": "2.92.0"],
                status: .succeeded, exitCode: 0, startedAt: ago(50), finishedAt: ago(50).addingTimeInterval(12)
            ),
            CommandHistoryEntry(
                planKind: .cleanup(.providerCache), providerID: .npm,
                commands: ["npm cache clean --force"],
                targets: [OperationTarget(packageName: "npm", displayName: "npm")],
                status: .succeeded, exitCode: 0, startedAt: ago(74), finishedAt: ago(74).addingTimeInterval(3)
            ),
            CommandHistoryEntry(
                planKind: .update, providerID: .uv,
                commands: ["uv tool upgrade kimi-cli"],
                targets: [OperationTarget(toolID: "kimi-cli", installationID: "uv:kimi-cli", packageName: "kimi-cli", displayName: "Kimi CLI", fromVersion: "1.48.2", toVersion: "1.49.0")],
                verifiedVersions: ["uv:kimi-cli": "1.48.2"],
                status: .unverified, exitCode: 0, startedAt: ago(98), finishedAt: ago(98).addingTimeInterval(9)
            ),
            CommandHistoryEntry(
                planKind: .uninstall, providerID: .homebrew,
                commands: ["brew uninstall php@8.3"],
                targets: [OperationTarget(packageName: "php@8.3", displayName: "php@8.3", fromVersion: "8.3.20")],
                status: .succeeded, exitCode: 0, startedAt: ago(150), finishedAt: ago(150).addingTimeInterval(6)
            ),
        ]
    }

    // MARK: Builders

    static func observed(_ version: String, _ source: ObservationSource, _ confidence: ObservationConfidence, _ date: Date) -> ObservedValue<ToolVersion> {
        ObservedValue(ToolVersion(version), source: source, confidence: confidence, observedAt: date)
    }

    static func brewInstallation(
        _ formula: String,
        version: String,
        latest: String,
        commands: [String],
        linkState: LinkState,
        architecture: CPUArchitecture = .arm64,
        resolvedDirectory: String = "bin",
        isDirect: Bool = true,
        dependencies: [String] = [],
        dependents: [String] = [],
        configPaths: [String] = [],
        at date: Date
    ) -> ToolInstallation {
        let prefix = "/opt/homebrew/Cellar/\(formula)/\(version)"
        let onPath = linkState != .notOnPath
        return ToolInstallation(
            id: .package(provider: .homebrew, name: formula),
            ownership: Ownership(provider: .homebrew, packageName: formula, confidence: .confirmed, evidence: [
                .inventoryContains(provider: .homebrew, package: formula),
                .symlinkResolvesInto("/opt/homebrew/Cellar/\(formula)/"),
            ]),
            version: observed(version, .provider(.homebrew), .confirmed, date),
            latest: observed(latest, .provider(.homebrew), .confirmed, date),
            executables: commands.map { name in
                ExecutableRef(
                    name: name,
                    path: onPath ? "/opt/homebrew/bin/\(name)" : "/opt/homebrew/opt/\(formula)/bin/\(name)",
                    resolvedPath: "\(prefix)/\(resolvedDirectory)/\(name)",
                    pathPriority: onPath ? 11 : nil,
                    architecture: architecture
                )
            },
            installPrefix: prefix,
            linkState: linkState,
            isDirect: isDirect,
            capabilities: ToolCapabilities(canUpdate: true, canUninstall: true, canOpenConfig: !configPaths.isEmpty),
            dependencies: dependencies,
            dependents: dependents,
            configPaths: configPaths
        )
    }

    static func npmInstallation(_ package: String, version: String, latest: String, commands: [String], entry: String, at date: Date) -> ToolInstallation {
        let root = "/opt/homebrew/lib/node_modules/\(package)"
        return ToolInstallation(
            id: .package(provider: .npm, instance: npmRoot, name: package),
            ownership: Ownership(provider: .npm, instance: npmRoot, packageName: package, confidence: .confirmed, evidence: [
                .inventoryContains(provider: .npm, package: package),
                .symlinkResolvesInto(root),
            ]),
            version: observed(version, .provider(.npm), .confirmed, date),
            latest: observed(latest, .provider(.npm), .confirmed, date),
            executables: commands.map { ExecutableRef(name: $0, path: "/opt/homebrew/bin/\($0)", resolvedPath: "\(root)/\(entry)", pathPriority: 11, architecture: .script) },
            installPrefix: root,
            linkState: .active,
            isDirect: true,
            capabilities: ToolCapabilities(canUpdate: true, canUninstall: true)
        )
    }

    static func systemInstallation(_ command: String, version: String, linkState: LinkState, at date: Date) -> ToolInstallation {
        ToolInstallation(
            id: .path("/usr/bin/\(command)"),
            ownership: Ownership(provider: .system, confidence: .confirmed, evidence: [.systemLocation("/usr/bin")]),
            version: observed(version, .executable("/usr/bin/\(command)"), .confirmed, date),
            executables: [ExecutableRef(name: command, path: "/usr/bin/\(command)", pathPriority: 15, architecture: .universal)],
            linkState: linkState,
            isSystemManaged: true
        )
    }

    static func tool(
        _ id: String,
        name: String,
        display: String,
        summary: String? = nil,
        category: ToolCategory,
        installations: [ToolInstallation],
        active: InstallationID? = nil,
        command: String?,
        service: ToolService? = nil,
        health: ToolHealth,
        issueIDs: [String] = [],
        homepage: String? = nil,
        at date: Date
    ) -> Tool {
        let chain = command.map { command in
            installations.flatMap(\.executables)
                .filter { $0.name == command && $0.pathPriority != nil }
                .sorted { ($0.pathPriority ?? .max) < ($1.pathPriority ?? .max) }
        } ?? []
        let activeID = active ?? installations.first { $0.linkState == .active }?.id
        return Tool(
            id: ToolID(id),
            identity: ToolIdentity(name: name, displayName: display, summary: summary, category: category, homepage: homepage.flatMap(URL.init(string:)), registryID: category == .unrecognized || category == .dependency ? nil : id),
            installations: installations,
            activeInstallationID: activeID,
            resolution: command.map { CommandResolution(command: $0, chain: chain) },
            service: service,
            health: ToolHealthState(status: health, issueIDs: issueIDs),
            lastScannedAt: date
        )
    }
}
