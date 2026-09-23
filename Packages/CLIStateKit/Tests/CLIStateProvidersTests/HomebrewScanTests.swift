@testable import CLIStateProviders
import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing

@Suite("Homebrew scan")
struct HomebrewScanTests {
    static let prefix = "/opt/homebrew"

    static func runner(infoStderr: String = "", servicesStderr: String = "") throws -> StubCommandRunner {
        let runner = StubCommandRunner()
        try runner.stub("brew", ["--version"], fixture: "Homebrew/version.txt")
        runner.stub("brew", ["--prefix"], stdout: "\(prefix)\n")
        try runner.stub("brew", ["info", "--json=v2", "--installed"], fixture: "Homebrew/info-installed.json", stderr: infoStderr)
        try runner.stub("brew", ["services", "list", "--json"], fixture: "Homebrew/services.json", stderr: servicesStderr)
        try runner.stub("brew", ["outdated", "--json=v2"], fixture: "Homebrew/outdated.json")
        return runner
    }

    static func fileSystem() -> InMemoryFileSystem {
        let fs = InMemoryFileSystem()
        for name in ["php", "php-cgi", "php-config", "phpize", "pear"] {
            fs.addExecutable("\(prefix)/Cellar/php/8.5.7/bin/\(name)")
        }
        fs.addExecutable("\(prefix)/Cellar/php/8.5.7/sbin/php-fpm")
        fs.addFile("\(prefix)/Cellar/php/8.5.7/bin/.hidden-helper", executable: true)
        fs.addFile("\(prefix)/Cellar/php/8.5.7/bin/README", executable: false)
        fs.addSymlink("\(prefix)/opt/php", to: "../Cellar/php/8.5.7")
        fs.addExecutable("\(prefix)/Cellar/ffmpeg/8.1.2_1/bin/ffmpeg")
        fs.addExecutable("\(prefix)/Cellar/ffmpeg/8.1.2_1/bin/ffprobe")
        fs.addSymlink("\(prefix)/opt/ffmpeg", to: "../Cellar/ffmpeg/8.1.2_1")
        // Keg-only without an opt link: falls back to the keg itself.
        fs.addExecutable("\(prefix)/Cellar/php@8.2/8.2.31/bin/php")
        return fs
    }

    static func scan(_ depth: ScanDepth = .fast, runner: StubCommandRunner? = nil) async throws -> (ProviderInventory, StubCommandRunner) {
        let runner = try runner ?? Self.runner()
        let provider = HomebrewProvider(runner: runner, fileSystem: fileSystem())
        return (try await provider.scan(context: TestContext.brew, depth: depth), runner)
    }

    static func tool(_ inventory: ProviderInventory, _ name: String) throws -> ProviderTool {
        try #require(inventory.tools.first { $0.packageName == name })
    }

    // MARK: Fixture

    @Test func parsesAllFormulaeAndOnlyCLICasks() async throws {
        let (inventory, _) = try await Self.scan()
        #expect(inventory.tools.filter { $0.kind == .formula }.count == 179)
        #expect(inventory.tools.filter { $0.kind == .cask }.map(\.packageName) == ["codexbar"])
        #expect(inventory.providerID == .homebrew)
        #expect(inventory.depth == .fast)
        #expect(inventory.scannedAt == TestContext.now)
        #expect(inventory.availability.isAvailable)
        #expect(inventory.availability.version == "6.0.22")
        #expect(inventory.availability.executable == "/opt/homebrew/bin/brew")
    }

    @Test func layoutComesFromBrewPrefix() async throws {
        let (inventory, _) = try await Self.scan()
        #expect(inventory.layout[.homebrewPrefix] == "/opt/homebrew")
        #expect(inventory.layout[.homebrewCellar] == "/opt/homebrew/Cellar")
        #expect(inventory.layout[.homebrewCaskroom] == "/opt/homebrew/Caskroom")
    }

    @Test func mapsPHP() async throws {
        let (inventory, _) = try await Self.scan()
        let php = try Self.tool(inventory, "php")
        #expect(php.kind == .formula)
        #expect(php.installedVersions == ["8.5.7"])
        #expect(php.activeVersion == "8.5.7")
        #expect(php.latestVersion == "8.5.10")
        #expect(php.isOutdated == true)
        #expect(php.isPinned == false)
        #expect(php.isDirect == false)
        #expect(php.isKegOnly == false)
        #expect(php.installPrefix == "/opt/homebrew/Cellar/php/8.5.7")
        #expect(php.summary == "General-purpose scripting language")
        #expect(php.homepage == "https://www.php.net/")
        #expect(php.dependencies.contains("openssl@3"))
        #expect(php.installedAt == Date(timeIntervalSince1970: 1_781_289_002))
        #expect(php.executableNames == ["pear", "php", "php-cgi", "php-config", "phpize", "php-fpm"])
        #expect(php.installationID == "homebrew:php")
        #expect(php.displayName == nil)
    }

    @Test func latestVersionAppendsRevision() async throws {
        let (inventory, _) = try await Self.scan()
        let ffmpeg = try Self.tool(inventory, "ffmpeg")
        // versions.stable 9.0.1 + revision 1, identical to `brew outdated`'s current_version.
        #expect(ffmpeg.latestVersion == "9.0.1_1")
        #expect(ffmpeg.activeVersion == "8.1.2_1")
        #expect(ffmpeg.isDirect == true)
        #expect(ffmpeg.executableNames == ["ffmpeg", "ffprobe"])
        #expect(HomebrewMapper.latestVersion(stable: "9.0.1", revision: 0) == "9.0.1")
        #expect(HomebrewMapper.latestVersion(stable: "9.0.1", revision: nil) == "9.0.1")
        #expect(HomebrewMapper.latestVersion(stable: nil, revision: 2) == nil)
    }

    @Test func kegOnlyFormula() async throws {
        let (inventory, _) = try await Self.scan()
        let php82 = try Self.tool(inventory, "php@8.2")
        #expect(php82.isKegOnly)
        #expect(php82.activeVersion == nil)
        #expect(php82.installPrefix == "/opt/homebrew/Cellar/php@8.2/8.2.31")
        #expect(php82.latestVersion == "8.2.33")
        #expect(php82.isDirect == true)
        #expect(php82.executableNames == ["php"])
    }

    @Test func unlinkedMultiVersionFormulaUsesLastInstalledKeg() async throws {
        let (inventory, _) = try await Self.scan()
        let sqlite = try Self.tool(inventory, "sqlite")
        #expect(sqlite.installedVersions == ["3.53.0", "3.53.1", "3.53.4"])
        #expect(sqlite.activeVersion == nil)
        #expect(sqlite.installPrefix == "/opt/homebrew/Cellar/sqlite/3.53.4")
        #expect(sqlite.executableNames.isEmpty)
    }

    @Test func directFormulaeMatchBrewLeaves() async throws {
        let (inventory, _) = try await Self.scan()
        let leaves = try Fixture.string("Homebrew/leaves.txt").split(separator: "\n").map(String.init)
        let direct = inventory.tools.filter { $0.kind == .formula && $0.isDirect == true }.map(\.packageName)
        #expect(direct.sorted() == leaves.sorted())
        #expect(inventory.tools.filter { $0.isKegOnly }.count == 19)
        #expect(inventory.tools.filter { $0.kind == .formula && $0.isOutdated == true }.count == 63)
    }

    @Test func caskWithBinaryArtifact() async throws {
        let (inventory, _) = try await Self.scan()
        let codexbar = try Self.tool(inventory, "codexbar")
        #expect(codexbar.kind == .cask)
        #expect(codexbar.displayName == "CodexBar")
        #expect(codexbar.executableNames == ["codexbar"])
        #expect(codexbar.executablePaths == ["/opt/homebrew/bin/codexbar"])
        #expect(codexbar.installedVersions == ["0.56.4"])
        #expect(codexbar.latestVersion == "0.60.0")
        #expect(codexbar.isOutdated == true)
        #expect(codexbar.installPrefix == "/opt/homebrew/Caskroom/codexbar/0.56.4")
        #expect(codexbar.installedAt == Date(timeIntervalSince1970: 1_788_462_928))
        #expect(!inventory.tools.contains { $0.packageName == "codexisland" || $0.packageName.hasPrefix("font-") })
    }

    @Test func services() async throws {
        let (inventory, _) = try await Self.scan()
        #expect(inventory.services.count == 5)
        let postgres = try #require(inventory.services.first { $0.name == "postgresql@17" })
        #expect(postgres.status == .running)
        #expect(postgres.rawStatus == "started")
        #expect(postgres.user == "tester")
        #expect(postgres.plistPath == "/Users/tester/Library/LaunchAgents/homebrew.mxcl.postgresql@17.plist")
        let caddy = try #require(inventory.services.first { $0.name == "caddy" })
        #expect(caddy.status == .stopped)
        #expect(caddy.rawStatus == "none")
        #expect(caddy.user == nil)
    }

    @Test("Service status mapping", arguments: [
        ("started", ServiceStatus.running),
        ("none", .stopped),
        ("stopped", .stopped),
        ("scheduled", .scheduled),
        ("error", .error),
        ("other", .unknown),
        ("unknown", .unknown),
    ])
    func serviceStatus(raw: String, expected: ServiceStatus) {
        #expect(HomebrewMapper.serviceStatus(raw) == expected)
    }

    // MARK: Commands

    @Test func fastScanRunsReadOnlyCommandsWithTimeouts() async throws {
        let (_, runner) = try await Self.scan(.fast)
        #expect(Set(runner.arguments(of: "brew")) == [
            ["--version"], ["--prefix"], ["info", "--json=v2", "--installed"], ["services", "list", "--json"],
        ])
        #expect(runner.commands.allSatisfy { $0.timeout == .seconds(30) })
        #expect(runner.commands.allSatisfy { $0.executable == "/opt/homebrew/bin/brew" })
    }

    @Test func everyScanCommandDisablesAutoUpdate() async throws {
        let (_, runner) = try await Self.scan(.deep)
        let provider = HomebrewProvider(runner: runner, fileSystem: Self.fileSystem())
        _ = await provider.availability(context: TestContext.brew)
        #expect(runner.commands.count == 6)
        for command in runner.commands {
            #expect(command.environmentOverrides["HOMEBREW_NO_AUTO_UPDATE"] == "1", "\(command.displayString)")
            #expect(command.environmentOverrides["HOMEBREW_NO_ENV_HINTS"] == "1", "\(command.displayString)")
        }
    }

    @Test func deepScanMergesOutdated() async throws {
        let (inventory, runner) = try await Self.scan(.deep)
        let outdated = try #require(runner.commands.first { $0.arguments == ["outdated", "--json=v2"] })
        #expect(outdated.timeout == .seconds(60))
        #expect(inventory.depth == .deep)
        #expect(try Self.tool(inventory, "codexbar").latestVersion == "0.60.0")
        #expect(try Self.tool(inventory, "php").latestVersion == "8.5.10")
    }

    @Test func outdatedIsAuthoritativeForCasksAndPins() {
        let tools = [Tools.cask("codexbar"), Tools.formula("node", active: "25.0.0", latest: "26.0.0")]
        let dto = BrewOutdatedDTO.decode("""
        {"formulae":[{"name":"node","installed_versions":["25.0.0"],"current_version":"26.1.0","pinned":true,"pinned_version":"25.0.0"}],
         "casks":[{"name":"codexbar","installed_versions":["0.56.4"],"current_version":"0.61.0","pinned":false}]}
        """)
        let merged = HomebrewMapper.merge(outdated: dto, into: tools)
        #expect(merged[0].latestVersion == "0.61.0")
        #expect(merged[0].isOutdated == true)
        #expect(merged[1].latestVersion == "26.1.0")
        #expect(merged[1].isPinned)
    }

    @Test func unavailableWithoutBrew() async throws {
        let provider = HomebrewProvider(runner: StubCommandRunner(), fileSystem: InMemoryFileSystem())
        let availability = await provider.availability(context: TestContext.empty)
        #expect(!availability.isAvailable)
        #expect(availability.reason == "executableNotFound")
        await #expect(throws: ProviderError.unavailable(.homebrew)) {
            try await provider.scan(context: TestContext.empty, depth: .fast)
        }
    }

    // MARK: Warnings and failures

    @Test func stderrBecomesDeduplicatedWarnings() async throws {
        let stderr = try Fixture.string("Homebrew/stderr-warnings.txt")
        let runner = try Self.runner(infoStderr: stderr, servicesStderr: stderr)
        let (inventory, _) = try await Self.scan(runner: runner)
        #expect(inventory.warnings.count == 2)
        #expect(inventory.warnings[0] == "Warning: You are using macOS 27.\nWe do not provide support for this pre-release version.")
        #expect(inventory.warnings[1].hasPrefix("Warning: The following taps are not trusted:"))
        #expect(inventory.warnings[1].contains("hudochenkov/sshpass"))
        #expect(inventory.warnings[1].hasSuffix("tap trust is required."))
        #expect(inventory.tools.count == 180)
    }

    @Test func malformedInfoThrowsParsingFailed() async throws {
        let runner = try Self.runner()
        runner.stub("brew", ["info", "--json=v2", "--installed"], stdout: "{ not json")
        await #expect(throws: ProviderError.parsingFailed(.homebrew, what: "brew info --json=v2 --installed")) {
            try await Self.scan(runner: runner)
        }
    }

    @Test func failingInfoThrowsCommandFailed() async throws {
        let runner = try Self.runner()
        runner.stub("brew", ["info", "--json=v2", "--installed"], stderr: "Error: boom\n", exitCode: 1)
        await #expect(throws: ProviderError.commandFailed(.homebrew, command: "brew info --json=v2 --installed", exitCode: 1, stderr: "Error: boom")) {
            try await Self.scan(runner: runner)
        }
    }

    @Test func emptyInventory() async throws {
        let runner = try Self.runner()
        runner.stub("brew", ["info", "--json=v2", "--installed"], stdout: #"{"formulae":[],"casks":[]}"#)
        runner.stub("brew", ["services", "list", "--json"], stdout: "[]")
        let (inventory, _) = try await Self.scan(runner: runner)
        #expect(inventory.tools.isEmpty)
        #expect(inventory.services.isEmpty)
        #expect(inventory.warnings.isEmpty)

        runner.stub("brew", ["info", "--json=v2", "--installed"], stdout: "{}")
        #expect(try await Self.scan(runner: runner).0.tools.isEmpty)
    }

    @Test func toleratesMissingWrongAndUnknownFields() async throws {
        let runner = try Self.runner()
        runner.stub("brew", ["info", "--json=v2", "--installed"], stdout: """
        {
          "formulae": [
            {"name": "minimal"},
            {"name": "odd", "revision": "one", "versions": {"stable": "1.2"}, "installed": [{"version": "1.1", "time": "yesterday", "installed_on_request": true}, 42], "linked_keg": 7, "future_field": {"x": [1, 2]}},
            {"full_name": "no-name"},
            "garbage"
          ],
          "casks": [
            {"token": "gui-only", "artifacts": [{"app": ["Gui.app"], "target": "/Applications/Gui.app"}]},
            {"token": "cli", "installed": "2.0", "artifacts": [{"binary": ["$APPDIR/Cli.app/Contents/MacOS/cli-tool"]}, "junk", {"binary": [{"target": "renamed"}, "/x/y"], "target": "/opt/homebrew/bin/renamed"}]}
          ],
          "brand_new_top_level": true
        }
        """)
        let (inventory, _) = try await Self.scan(runner: runner)
        #expect(inventory.tools.map(\.packageName) == ["minimal", "odd", "cli"])

        let minimal = try Self.tool(inventory, "minimal")
        #expect(minimal.installedVersions.isEmpty)
        #expect(minimal.latestVersion == nil)
        #expect(minimal.isDirect == nil)
        #expect(minimal.isOutdated == nil)
        #expect(minimal.installPrefix == nil)

        let odd = try Self.tool(inventory, "odd")
        #expect(odd.latestVersion == "1.2")
        #expect(odd.installedVersions == ["1.1"])
        #expect(odd.activeVersion == nil)
        #expect(odd.installedAt == nil)
        #expect(odd.isDirect == true)

        let cli = try Self.tool(inventory, "cli")
        #expect(cli.executableNames == ["cli-tool", "renamed"])
        #expect(cli.executablePaths == ["/opt/homebrew/bin/renamed"])
        #expect(cli.latestVersion == nil)
    }

    @Test func nonFatalCommandFailuresBecomeWarnings() async throws {
        let runner = try Self.runner()
        runner.stub("brew", ["--prefix"], exitCode: 1)
        runner.stub("brew", ["services", "list", "--json"], stderr: "Error: services unavailable", exitCode: 1)
        runner.stub("brew", ["outdated", "--json=v2"], stdout: "not json")
        let (inventory, _) = try await Self.scan(.deep, runner: runner)
        #expect(inventory.tools.count == 180)
        #expect(inventory.services.isEmpty)
        #expect(inventory.layout[.homebrewPrefix] == "/opt/homebrew")
        #expect(inventory.warnings.contains("Error: services unavailable"))
        #expect(inventory.warnings.contains { $0.contains("brew --prefix failed") })
        #expect(inventory.warnings.contains { $0.contains("brew services list --json failed") })
        #expect(inventory.warnings.contains { $0.contains("brew outdated --json=v2 failed") })
    }
}

extension BrewOutdatedDTO {
    static func decode(_ json: String) -> BrewOutdatedDTO {
        try! JSONDecoder().decode(BrewOutdatedDTO.self, from: Data(json.utf8))
    }
}

@Suite("Homebrew metadata age")
struct HomebrewMetadataTests {
    @Test func newestIndexOrFetchWins() {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        let morning = Date(timeIntervalSince1970: 1_800_000_000)
        let noon = morning.addingTimeInterval(3 * 3600)
        fs.addFile("/opt/homebrew/.git/FETCH_HEAD", modifiedAt: morning)
        fs.addFile("/Users/tester/Library/Caches/Homebrew/api/internal/packages.arm64_golden_gate.jws.json", modifiedAt: noon)
        fs.addFile("/Users/tester/Library/Caches/Homebrew/api/internal/executables.txt", modifiedAt: noon.addingTimeInterval(3600))
        #expect(HomebrewMetadata.lastUpdated(prefix: "/opt/homebrew", cacheDirectory: nil, fileSystem: fs) == noon)
    }

    @Test func honorsHomebrewCacheAndReportsNothingWithoutAnIndex() {
        let fs = InMemoryFileSystem(home: "/Users/tester")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        fs.addFile("/Volumes/Cache/Homebrew/api/cask.jws.json", modifiedAt: date)
        #expect(HomebrewMetadata.lastUpdated(prefix: "/opt/homebrew", cacheDirectory: "/Volumes/Cache/Homebrew", fileSystem: fs) == date)
        #expect(HomebrewMetadata.lastUpdated(prefix: "/usr/local", cacheDirectory: nil, fileSystem: InMemoryFileSystem()) == nil)
    }
}
