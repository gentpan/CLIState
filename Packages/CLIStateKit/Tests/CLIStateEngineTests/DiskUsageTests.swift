import CLIStateDomain
@testable import CLIStateEngine
import CLIStateTestSupport
import Foundation
import Testing

@Suite("Disk usage")
struct DiskUsageTests {
    private func measurer(_ fs: InMemoryFileSystem, entryLimit: Int = DiskUsageMeasurer.defaultEntryLimit) -> DiskUsageMeasurer {
        DiskUsageMeasurer(fileSystem: fs, context: AttributionContext(homeDirectory: home, variables: [:], inventories: []), entryLimit: entryLimit)
    }

    private func bytes(_ count: Int) -> Data { Data(count: count) }

    private func installation(_ provider: ProviderID, prefix: String?, executables: [ExecutableRef] = [], version: String? = nil, systemManaged: Bool = false) -> ToolInstallation {
        ToolInstallation(
            id: .path(executables.first?.path ?? prefix ?? "/x"),
            ownership: Ownership(provider: provider, confidence: .confirmed),
            version: version.map { ObservedValue(ToolVersion($0), source: .path, confidence: .confirmed, observedAt: scanDate) },
            executables: executables,
            installPrefix: prefix,
            linkState: .active,
            isSystemManaged: systemManaged
        )
    }

    // MARK: Walking

    @Test func walkSumsRegularFilesWithoutFollowingSymlinks() throws {
        let fs = InMemoryFileSystem(home: home)
        let keg = "/opt/homebrew/Cellar/jq/1.8.1"
        fs.addFile("\(keg)/bin/jq", contents: bytes(1_000), executable: true)
        fs.addFile("\(keg)/share/man/jq.1", contents: bytes(200))
        fs.addFile("/opt/big/blob", contents: bytes(1_000_000))
        fs.addSymlink("\(keg)/lib/blob", to: "/opt/big/blob")
        fs.addSymlink("\(keg)/lib/big", to: "/opt/big")
        fs.addHardLink("\(keg)/bin/jq-again", to: "\(keg)/bin/jq")

        let measurement = try #require(measurer(fs).measure([.tree(keg)]))
        #expect(measurement.bytes == 1_200, "symlinks aren't followed and a hard link counts once")
        #expect(!measurement.isPartial)
    }

    @Test func walkStopsAtTheEntryLimit() throws {
        let fs = InMemoryFileSystem(home: home)
        let root = "\(home)/.local/share/uv/tools/huge"
        for index in 0..<10 { fs.addFile("\(root)/file\(index)", contents: bytes(10)) }

        let capped = try #require(measurer(fs, entryLimit: 4).measure([.tree(root)]))
        #expect(capped.isPartial)
        #expect(capped.bytes == 40)
        let full = try #require(measurer(fs).measure([.tree(root)]))
        #expect(!full.isPartial && full.bytes == 100)
    }

    @Test func missingTargetsAreNotMeasured() {
        let fs = InMemoryFileSystem(home: home)
        #expect(measurer(fs).measure([.tree("/opt/homebrew/Cellar/gone/1.0"), .file("/opt/homebrew/bin/gone")]) == nil)
    }

    @Test func pnpmPackageLinkedIntoTheStoreIsResolvedOnce() throws {
        let fs = InMemoryFileSystem(home: home)
        let root = "\(home)/Library/pnpm/global/5/node_modules"
        fs.addFile("\(root)/.pnpm/cowsay@1.6.0/node_modules/cowsay/index.js", contents: bytes(300))
        fs.addSymlink("\(root)/cowsay", to: "\(root)/.pnpm/cowsay@1.6.0/node_modules/cowsay")

        let targets = measurer(fs).targets(for: installation(.pnpm, prefix: "\(root)/cowsay"), registryID: nil)
        #expect(targets == [.tree("\(root)/cowsay")])
        #expect(measurer(fs).measure(targets)?.bytes == 300)
    }

    // MARK: Targets

    @Test func homebrewFormulaMeasuresItsKeg() {
        let fs = InMemoryFileSystem(home: home)
        let keg = "/opt/homebrew/Cellar/node/26.7.0"
        let brew = installation(.homebrew, prefix: keg, executables: [ExecutableRef(name: "node", path: "/opt/homebrew/bin/node", resolvedPath: "\(keg)/bin/node")])
        #expect(measurer(fs).targets(for: brew, registryID: "node") == [.tree(keg)])
    }

    @Test func caskMeasuresItsCaskroomAndTheAppsItInstalled() throws {
        let fs = InMemoryFileSystem(home: home)
        let version = "/opt/homebrew/Caskroom/codexbar/0.56.4"
        fs.addFile("\(version)/.metadata", contents: bytes(5))
        fs.addFile("/Applications/CodexBar.app/Contents/MacOS/CodexBar", contents: bytes(4_000))
        fs.addFile("/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI", contents: bytes(1_000), executable: true)
        fs.addSymlink("\(version)/CodexBar.app", to: "/Applications/CodexBar.app")
        fs.addFile("/Applications/Docker.app/Contents/Resources/bin/docker", contents: bytes(20_000), executable: true)
        let cask = installation(.homebrew, prefix: version, executables: [
            ExecutableRef(name: "codexbar", path: "/opt/homebrew/bin/codexbar", resolvedPath: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"),
            ExecutableRef(name: "docker", path: "/usr/local/bin/docker", resolvedPath: "/Applications/Docker.app/Contents/Resources/bin/docker"),
        ])

        let targets = measurer(fs).targets(for: cask, registryID: nil)
        #expect(targets == [.tree(version), .tree("/Applications/CodexBar.app"), .tree("/Applications/Docker.app")])
        #expect(measurer(fs).measure(targets)?.bytes == 25_005, "the app linked from the Caskroom counts once")
    }

    @Test func packageManagersMeasureTheirPackageDirectory() {
        let fs = InMemoryFileSystem(home: home)
        let cases: [(ProviderID, String)] = [
            (.npm, "/opt/homebrew/lib/node_modules/@openai/codex"),
            (.bun, "\(home)/.bun/install/global/node_modules/@opencode-ai/cli"),
            (.uv, "\(home)/.local/share/uv/tools/kimi-cli"),
            (.pipx, "\(home)/.local/pipx/venvs/black"),
            (.nvm, "\(home)/.nvm/versions/node/v22.11.0"),
            (.rustup, "\(home)/.rustup/toolchains/stable-aarch64-apple-darwin"),
            (.appBundle, "/Applications/Visual Studio Code.app"),
        ]
        for (provider, prefix) in cases {
            #expect(measurer(fs).targets(for: installation(provider, prefix: prefix), registryID: nil) == [.tree(prefix)], "\(provider)")
        }
    }

    @Test func cargoMeasuresOnlyItsOwnBinaries() throws {
        let fs = InMemoryFileSystem(home: home)
        let bin = "\(home)/.cargo/bin"
        fs.addFile("\(bin)/deepseek", contents: bytes(8_000), executable: true)
        fs.addFile("\(bin)/other-crate", contents: bytes(90_000), executable: true)
        let cargo = installation(.cargo, prefix: bin, executables: [ExecutableRef(name: "deepseek", path: "\(bin)/deepseek")])

        let targets = measurer(fs).targets(for: cargo, registryID: nil)
        #expect(targets == [.file("\(bin)/deepseek")])
        #expect(measurer(fs).measure(targets)?.bytes == 8_000)
    }

    @Test func nativeInstallersMeasureTheVersionEntryOrTheExecutables() throws {
        let fs = InMemoryFileSystem(home: home)
        let claudeVersion = "\(home)/.local/share/claude/versions/2.1.234"
        fs.addFile(claudeVersion, contents: bytes(310_000), executable: true)
        fs.addSymlink("\(home)/.local/bin/claude", to: claudeVersion)
        let claude = installation(.native, prefix: claudeVersion, executables: [ExecutableRef(name: "claude", path: "\(home)/.local/bin/claude", resolvedPath: claudeVersion)])
        #expect(measurer(fs).targets(for: claude, registryID: "claude-code") == [.tree(claudeVersion)])
        #expect(measurer(fs).measure([.tree(claudeVersion)])?.bytes == 310_000)

        // `~/.bun/bin` shares `~/.bun` with the install cache: only the binaries count.
        fs.addFile("\(home)/.bun/bin/bun", contents: bytes(60_000), executable: true)
        fs.addFile("\(home)/.bun/install/cache/huge.tgz", contents: bytes(900_000))
        fs.addSymlink("\(home)/.bun/bin/bunx", to: "\(home)/.bun/bin/bun")
        let bun = installation(.native, prefix: "\(home)/.bun", executables: [
            ExecutableRef(name: "bun", path: "\(home)/.bun/bin/bun"),
            ExecutableRef(name: "bunx", path: "\(home)/.bun/bin/bunx", resolvedPath: "\(home)/.bun/bin/bun"),
        ])
        let targets = measurer(fs).targets(for: bun, registryID: "bun")
        #expect(targets == [.file("\(home)/.bun/bin/bun")])
        #expect(measurer(fs).measure(targets)?.bytes == 60_000)
    }

    @Test func standaloneMeasuresTheResolvedExecutableAndSystemIsSkipped() throws {
        let fs = InMemoryFileSystem(home: home)
        fs.addFile("\(home)/.grok/downloads/grok-1.0.25", contents: bytes(138_000), executable: true)
        fs.addFile("\(home)/.grok/downloads/grok-1.0.24", contents: bytes(137_000), executable: true)
        fs.addSymlink("\(home)/.grok/bin/grok", to: "\(home)/.grok/downloads/grok-1.0.25")
        let grok = installation(.standalone, prefix: nil, executables: [ExecutableRef(name: "grok", path: "\(home)/.grok/bin/grok")])
        #expect(measurer(fs).targets(for: grok, registryID: nil) == [.file("\(home)/.grok/downloads/grok-1.0.25")])

        let git = installation(.system, prefix: nil, executables: [ExecutableRef(name: "git", path: "/usr/bin/git")], systemManaged: true)
        #expect(measurer(fs).targets(for: git, registryID: "git").isEmpty)
    }

    @Test func sharedAndProtectedLocationsAreNeverWalked() {
        let fs = InMemoryFileSystem(home: home)
        for prefix in [home, "/Users", "/opt/homebrew", "\(home)/Documents/tools/venv", "\(home)/Library/Mobile Documents/x/y", "/Volumes/External/node_modules/x"] {
            #expect(measurer(fs).targets(for: installation(.uv, prefix: prefix), registryID: nil).isEmpty, "\(prefix)")
        }
        let documents = installation(.standalone, prefix: nil, executables: [ExecutableRef(name: "tool", path: "\(home)/Documents/bin/tool", resolvedPath: "\(home)/Documents/bin/tool")])
        #expect(measurer(fs).targets(for: documents, registryID: nil).isEmpty)
    }

    // MARK: Scans

    private func jqScenario(version: String = "1.8.1", size: Int = 5_000) -> (EngineScenario, ProviderInventory) {
        let scenario = EngineScenario()
        let keg = "/opt/homebrew/Cellar/jq/\(version)"
        scenario.fs.addFile("\(keg)/bin/jq", contents: bytes(size), executable: true)
        scenario.link("/opt/homebrew/bin/jq", to: "../Cellar/jq/\(version)/bin/jq")
        return (scenario, homebrewInventory([formula("jq", version, executables: ["jq"])]))
    }

    private func jq(_ snapshot: EnvironmentSnapshot) -> ToolInstallation? {
        snapshot.tools.lazy.flatMap(\.installations).first { $0.id == .package(provider: .homebrew, name: "jq") }
    }

    @Test func deepScanMeasuresAndFastScanCarriesItForward() async throws {
        let (scenario, inventory) = jqScenario()
        let deep = await scenario.build(inventories: [inventory], depth: .deep, updateSources: [StubUpdateSource(result: nil)])
        let measured = try #require(jq(deep)?.diskUsage)
        #expect(measured == DiskUsage(bytes: 5_000, measuredAt: scanDate, version: "1.8.1"))

        // The keg grew, but the version didn't change: fast scans don't walk it again.
        scenario.fs.addFile("/opt/homebrew/Cellar/jq/1.8.1/share/extra", contents: bytes(1_000))
        let later = scanDate.addingTimeInterval(3600)
        let fast = await scenario.build(inventories: [inventory], previous: deep, now: later)
        #expect(jq(fast)?.diskUsage == measured)

        // A fresh measurement survives a deep scan; a day-old one is re-measured.
        let soon = await scenario.build(inventories: [inventory], previous: fast, depth: .deep, updateSources: [StubUpdateSource(result: nil)], now: later)
        #expect(jq(soon)?.diskUsage == measured)
        let nextDay = scanDate.addingTimeInterval(25 * 3600)
        let refreshed = await scenario.build(inventories: [inventory], previous: soon, depth: .deep, updateSources: [StubUpdateSource(result: nil)], now: nextDay)
        #expect(jq(refreshed)?.diskUsage == DiskUsage(bytes: 6_000, measuredAt: nextDay, version: "1.8.1"))
    }

    @Test func changedVersionDropsTheCarriedMeasurement() async throws {
        let (scenario, inventory) = jqScenario()
        let deep = await scenario.build(inventories: [inventory], depth: .deep, updateSources: [StubUpdateSource(result: nil)])
        #expect(jq(deep)?.diskUsage?.bytes == 5_000)

        let (upgraded, newInventory) = jqScenario(version: "1.9.0", size: 7_000)
        let later = scanDate.addingTimeInterval(600)
        // A few changed installations (an upgrade) are measured right away…
        let fast = await upgraded.build(inventories: [newInventory], previous: deep, now: later)
        #expect(jq(fast)?.diskUsage == DiskUsage(bytes: 7_000, measuredAt: later, version: "1.9.0"))

        // …many (a first scan) wait for the deep scan instead of carrying a wrong size.
        upgraded.diskUsagePolicy = DiskUsagePolicy(fastScanLimit: 0)
        let limited = await upgraded.build(inventories: [newInventory], previous: deep, now: later)
        #expect(jq(limited)?.diskUsage == nil)
    }

    @Test func singleFileInstallationsAreMeasuredOnEveryScan() async throws {
        let scenario = EngineScenario()
        let path = "\(home)/.local/bin/mytool"
        scenario.fs.addFile(path, contents: bytes(2_000), executable: true)
        let first = await scenario.build()
        let tool = try #require(first.tools.first { $0.identity.name == "mytool" })
        #expect(tool.installations.first?.diskUsage == DiskUsage(bytes: 2_000, measuredAt: scanDate, version: nil))

        // Unchanged: same value. Replaced in place (no version to compare): new size.
        let later = scanDate.addingTimeInterval(60)
        let same = await scenario.build(previous: first, now: later)
        #expect(same.tools.first { $0.identity.name == "mytool" }?.installations.first?.diskUsage?.bytes == 2_000)
        scenario.fs.addFile(path, contents: bytes(3_000), executable: true)
        let replaced = await scenario.build(previous: same, now: later)
        #expect(replaced.tools.first { $0.identity.name == "mytool" }?.installations.first?.diskUsage == DiskUsage(bytes: 3_000, measuredAt: later, version: nil))
    }

    // MARK: Compatibility

    @Test func snapshotsWithoutUsageFieldsStillDecode() async throws {
        let (scenario, inventory) = jqScenario()
        let path = "/opt/homebrew/Cellar/jq/1.8.1/bin/jq"
        scenario.fs.setAccessedAt(path, scanDate.addingTimeInterval(-3600))
        var snapshot = await scenario.build(inventories: [inventory], depth: .deep, updateSources: [StubUpdateSource(result: nil)])
        snapshot.versionCache = ["/x/tool": CachedVersion(version: "1.0", size: 1, modifiedAt: scanDate, probe: "tool --version", probedAt: scanDate)]
        #expect(jq(snapshot)?.lastUsedAt != nil && jq(snapshot)?.diskUsage != nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        #expect(try decoder.decode(EnvironmentSnapshot.self, from: data) == snapshot)

        // What an app version from before these fields wrote.
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let legacy = try JSONSerialization.data(withJSONObject: Self.removingKeys(["diskUsage", "lastUsedAt", "probedAt"], from: object))
        let decoded = try decoder.decode(EnvironmentSnapshot.self, from: legacy)
        #expect(jq(decoded)?.diskUsage == nil)
        #expect(jq(decoded)?.lastUsedAt == nil)
        #expect(decoded.versionCache["/x/tool"]?.probedAt == nil)
        #expect(decoded.versionCache["/x/tool"]?.version == "1.0")
    }

    private static func removingKeys(_ keys: Set<String>, from value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.filter { !keys.contains($0.key) }.mapValues { removingKeys(keys, from: $0) }
        }
        if let array = value as? [Any] { return array.map { removingKeys(keys, from: $0) } }
        return value
    }
}
