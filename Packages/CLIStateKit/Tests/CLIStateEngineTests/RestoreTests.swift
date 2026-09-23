import CLIStateDomain
@testable import CLIStateEngine
import Foundation
import Testing

/// Snapshots for restore tests, built directly instead of through a scan.
enum RestoreFixture {
    static let home = "/Users/tester"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Stand-in for the provider layer's validator (Engine can't import Providers).
    static let isValidName: @Sendable (String) -> Bool = { name in
        !name.isEmpty && !name.hasPrefix("-") && !name.hasPrefix("/") && !name.hasPrefix(".") && !name.contains(" ") && !name.contains("~")
    }

    static func installation(_ provider: ProviderID, _ package: String, version: String?, confidence: AttributionConfidence = .confirmed, prefix: String? = nil, isDirect: Bool? = true, systemManaged: Bool = false) -> ToolInstallation {
        ToolInstallation(
            id: .package(provider: provider, name: package),
            ownership: Ownership(provider: provider, packageName: package, confidence: confidence),
            version: version.map { ObservedValue(ToolVersion($0), source: .provider(provider), confidence: .confirmed, observedAt: now) },
            executables: [ExecutableRef(name: package, path: "\(home)/bin/\(package)")],
            installPrefix: prefix ?? "\(home)/.local/share/\(provider.rawValue)/\(package)",
            linkState: .active,
            isDirect: isDirect,
            isSystemManaged: systemManaged
        )
    }

    static func tool(_ id: String, registryID: String? = nil, category: ToolCategory = .developerTool, _ installations: [ToolInstallation]) -> Tool {
        Tool(
            id: ToolID(id),
            identity: ToolIdentity(name: id, displayName: id, category: category, registryID: registryID),
            installations: installations,
            activeInstallationID: installations.first?.id,
            health: ToolHealthState(status: .healthy),
            lastScannedAt: now
        )
    }

    static func provider(_ id: ProviderID, available: Bool, layout: ProviderLayout = ProviderLayout()) -> ProviderSnapshot {
        ProviderSnapshot(providerID: id, availability: ProviderAvailability(providerID: id, isAvailable: available), layout: layout, freshness: .fresh(now))
    }

    static func snapshot(tools: [Tool], available: Set<ProviderID> = [.homebrew, .npm, .uv]) -> EnvironmentSnapshot {
        let shell = ShellEnvironment(shell: ShellDescriptor(executable: "/bin/zsh", kind: .zsh), path: ["/opt/homebrew/bin"], variables: ["HOME": home], source: .loginShell, capturedAt: now)
        let providers = [ProviderID.homebrew, .npm, .pnpm, .uv, .pipx, .cargo].map { id in
            provider(id, available: available.contains(id), layout: id == .homebrew ? ProviderLayout(roots: [.homebrewPrefix: "/opt/homebrew", .homebrewCaskroom: "/opt/homebrew/Caskroom"]) : ProviderLayout())
        }
        return EnvironmentSnapshot(capturedAt: now, depth: .fast, shell: shell, pathEntries: [], brokenSymlinks: [], providers: providers, tools: tools, services: [], issues: [])
    }

    /// A realistic mix: direct and dependency formulae, a cask, a tapped formula,
    /// npm's own packages, uv, a source-pinned crate, system and unowned tools.
    static func workstation() -> (EnvironmentSnapshot, [ProviderTool]) {
        let tools = [
            tool("git", registryID: "git", [installation(.homebrew, "git", version: "2.51.0", prefix: "/opt/homebrew/Cellar/git/2.51.0")]),
            tool("python", registryID: "python", category: .runtime, [installation(.homebrew, "python@3.14", version: "3.14.0", prefix: "/opt/homebrew/Cellar/python@3.14/3.14.0", isDirect: false)]),
            tool("homebrew.openssl@3", category: .dependency, [installation(.homebrew, "openssl@3", version: "3.5.2", prefix: "/opt/homebrew/Cellar/openssl@3/3.5.2", isDirect: false)]),
            tool("homebrew.ghostty", [installation(.homebrew, "ghostty", version: "1.2.0", prefix: "/opt/homebrew/Caskroom/ghostty/1.2.0")]),
            tool("homebrew.codexbar", [installation(.homebrew, "codexbar", version: "0.56.4", prefix: "/opt/homebrew/Caskroom/codexbar/0.56.4")]),
            tool("terraform", registryID: "terraform", [installation(.homebrew, "terraform", version: "1.13.3", prefix: "/opt/homebrew/Cellar/terraform/1.13.3")]),
            tool("npm", registryID: "npm", category: .packageManager, [installation(.npm, "npm", version: "11.6.0")]),
            tool("claude-code", registryID: "claude-code", category: .aiCLI, [installation(.npm, "@anthropic-ai/claude-code", version: "2.1.270")]),
            tool("kimi-cli", registryID: "kimi-cli", category: .aiCLI, [installation(.uv, "kimi-cli", version: "1.49.0")]),
            tool("cargo.local-tool", [installation(.cargo, "local-tool", version: "0.1.0")]),
            tool("cargo.bat", [installation(.cargo, "bat", version: "0.25.0")]),
            tool("curl", registryID: "curl", [installation(.system, "curl", version: "8.7.1", systemManaged: true)]),
            tool("node", registryID: "node", category: .runtime, [installation(.standalone, "node", version: "24.0.0", confidence: .unknown)]),
            tool("aider", registryID: "aider", category: .aiCLI, [installation(.pipx, "aider-chat", version: "0.86.0", confidence: .probable)]),
            tool("unknown.1", category: .unrecognized, [installation(.homebrew, "mystery", version: "1.0")]),
        ]
        let packages = [
            ProviderTool(providerID: .homebrew, packageName: "git", kind: .formula, isPinned: true, isDirect: true),
            ProviderTool(providerID: .homebrew, packageName: "codexbar", kind: .cask, isDirect: true, tap: "steipete/tap"),
            ProviderTool(providerID: .homebrew, packageName: "terraform", kind: .formula, isDirect: true, tap: "hashicorp/tap"),
            ProviderTool(providerID: .cargo, packageName: "local-tool", kind: .tool, isPinned: true, isDirect: true),
        ]
        return (snapshot(tools: tools, available: [.homebrew, .npm, .uv, .cargo]), packages)
    }
}

@Suite("Restore export")
struct ProfileExportTests {
    let exporter = ProfileExporter(isValidName: RestoreFixture.isValidName)

    @Test func exportsOnlyPackagesTheUserInstalledOnPurpose() throws {
        let (snapshot, packages) = RestoreFixture.workstation()
        let profile = exporter.profile(from: snapshot, packages: packages, source: ProfileSource(architecture: "arm64"), name: "  Work  ", note: " ", createdAt: RestoreFixture.now)

        #expect(profile.items.map(\.id) == [
            "homebrew-cask:ghostty",
            "homebrew-cask:steipete/tap/codexbar",
            "homebrew-formula:git",
            "homebrew-formula:hashicorp/tap/terraform",
            "npm:@anthropic-ai/claude-code",
            "uv:kimi-cli",
            "cargo:bat",
        ])
        #expect(profile.name == "Work")
        #expect(profile.note == nil)
        let git = try #require(profile.items.first { $0.packageName == "git" })
        #expect(git.toolID == "git" && git.version == "2.51.0" && git.pinned)
        let terraform = try #require(profile.items.first { $0.packageName == "terraform" })
        #expect(terraform.tap == "hashicorp/tap" && terraform.toolID == "terraform")
        #expect(profile.items.first { $0.packageName == "kimi-cli" }?.pinned == false)
    }

    @Test func recognisesCasksByPrefixWithoutInventories() {
        let (snapshot, _) = RestoreFixture.workstation()
        let profile = exporter.profile(from: snapshot, createdAt: RestoreFixture.now)
        #expect(profile.items.filter { $0.provider == .homebrewCask }.map(\.packageName) == ["codexbar", "ghostty"])
        #expect(profile.items.allSatisfy { $0.tap == nil })
        // Without the inventory the source pin is unknown, so the crate is kept.
        #expect(profile.items.contains { $0.packageName == "local-tool" })
    }

    @Test func neverWritesTheHomeDirectoryOrEnvironment() throws {
        var (snapshot, packages) = RestoreFixture.workstation()
        snapshot.shell.variables["SECRET_TOKEN"] = "sk-live-123"
        snapshot.tools.append(RestoreFixture.tool("npm.evil", [RestoreFixture.installation(.npm, "\(RestoreFixture.home)/evil", version: "1.0")]))
        let data = try exporter.profile(from: snapshot, packages: packages, createdAt: RestoreFixture.now).encoded()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(RestoreFixture.home))
        #expect(!text.contains("tester"))
        #expect(!text.contains("sk-live"))
        #expect(!text.contains("Cellar") && !text.contains("Caskroom"))
    }

    @Test func writesTapBrewAndCaskLinesOnly() {
        let (snapshot, packages) = RestoreFixture.workstation()
        var profile = exporter.profile(from: snapshot, packages: packages, createdAt: RestoreFixture.now)
        profile.items.append(ProfileItem(provider: .homebrewFormula, packageName: "-evil"))
        profile.items.append(ProfileItem(provider: .homebrewFormula, packageName: "wget", tap: "bad tap"))
        #expect(BrewfileWriter.brewfile(for: profile, isValidName: RestoreFixture.isValidName) == """
        tap "steipete/tap"
        tap "hashicorp/tap"
        brew "git"
        brew "hashicorp/tap/terraform"
        cask "ghostty"
        cask "steipete/tap/codexbar"

        """)
        #expect(BrewfileWriter.brewfile(for: EnvironmentProfile(createdAt: RestoreFixture.now, items: [ProfileItem(provider: .npm, packageName: "x")]), isValidName: RestoreFixture.isValidName) == "")
    }
}

@Suite("Restore templates")
struct RestoreTemplateTests {
    let catalog = RestoreCatalog()

    @Test func everyTemplateItemResolvesToARegistryPackage() throws {
        let templates = catalog.templates
        #expect(templates.map(\.id) == ["frontend-web", "node-fullstack", "python-data", "php-laravel", "go-backend", "rust", "apple-platforms", "ai-cli", "devops-cloud"])
        for spec in RestoreCatalog.specToolIDs {
            let definition = try #require(catalog.registry.definition(spec.tool), "\(spec.template): \(spec.tool) is not in the registry")
            let item = try #require(catalog.item(for: spec.tool, provider: spec.provider), "\(spec.template): \(spec.tool) has no installable package")
            let providerID = try #require(item.provider.providerID)
            #expect(definition.packages[providerID]?.contains(item.qualifiedName) == true, "\(spec.template): \(item.id)")
            #expect(RestoreFixture.isValidName(item.packageName))
            if let override = spec.provider { #expect(providerID == override) }
        }
        for template in templates {
            #expect(template.items.count == RestoreCatalog.specs.first { $0.id == template.id }?.tools.count)
            #expect(Set(template.items.map(\.id)).count == template.items.count)
            #expect(template.items.allSatisfy { $0.toolID != nil && $0.version == nil })
        }
    }

    @Test func prefersHomebrewButAICLIsFromNPM() throws {
        #expect(catalog.item(for: "git")?.provider == .homebrewFormula)
        #expect(catalog.item(for: "claude-code") == ProfileItem(toolID: "claude-code", provider: .npm, packageName: "@anthropic-ai/claude-code"))
        #expect(catalog.item(for: "kimi-cli")?.provider == .uv)
        #expect(catalog.item(for: "terraform") == ProfileItem(toolID: "terraform", provider: .homebrewFormula, packageName: "terraform", tap: "hashicorp/tap"))
        #expect(catalog.item(for: "cargo-nextest", provider: .cargo)?.provider == .cargo)
        #expect(catalog.item(for: "homebrew") == nil)
        #expect(catalog.item(for: "git", provider: .npm) == nil)
    }

    @Test func candidatesAreExactlyTheInstallableRegistryTools() {
        let candidates = catalog.candidates
        let ids = Set(candidates.map(\.toolID))
        #expect(!ids.contains("homebrew") && !ids.contains("pip") && !ids.contains("gem") && !ids.contains("cargo"))
        #expect(ids.isSuperset(of: Set(catalog.templates.flatMap(\.items).compactMap(\.toolID))))
        #expect(candidates.count == Set(candidates.map(\.toolID)).count)
    }
}

@Suite("Restore diff")
struct ProfileDiffTests {
    let differ = ProfileDiffer(isValidName: RestoreFixture.isValidName)

    @Test func classifiesEveryItem() throws {
        let tools = [
            RestoreFixture.tool("git", registryID: "git", [RestoreFixture.installation(.homebrew, "git", version: "2.52.0")]),
            RestoreFixture.tool("jq", registryID: "jq", [RestoreFixture.installation(.homebrew, "jq", version: "1.6")]),
            RestoreFixture.tool("node", registryID: "node", category: .runtime, [RestoreFixture.installation(.nvm, "node", version: "24.1.0", confidence: .probable)]),
            RestoreFixture.tool("postgresql", registryID: "postgresql", category: .database, [RestoreFixture.installation(.homebrew, "postgresql@17", version: "17.6")]),
            RestoreFixture.tool("curl", registryID: "curl", [RestoreFixture.installation(.system, "curl", version: "8.7.1", systemManaged: true)]),
            RestoreFixture.tool("ffmpeg", registryID: "ffmpeg", [RestoreFixture.installation(.standalone, "ffmpeg", version: "8.0", confidence: .unknown)]),
            RestoreFixture.tool("terraform", registryID: "terraform", [RestoreFixture.installation(.homebrew, "terraform", version: "1.13.3")]),
        ]
        let snapshot = RestoreFixture.snapshot(tools: tools, available: [.homebrew, .npm])
        let profile = EnvironmentProfile(createdAt: RestoreFixture.now, items: [
            ProfileItem(toolID: "git", provider: .homebrewFormula, packageName: "git", version: "2.51.0"),
            ProfileItem(toolID: "jq", provider: .homebrewFormula, packageName: "jq", version: "1.7.1"),
            ProfileItem(toolID: "node", provider: .homebrewFormula, packageName: "node", version: "24.0.0"),
            ProfileItem(toolID: "postgresql", provider: .homebrewFormula, packageName: "postgresql@16"),
            ProfileItem(toolID: "curl", provider: .homebrewFormula, packageName: "curl"),
            ProfileItem(toolID: "ffmpeg", provider: .homebrewFormula, packageName: "ffmpeg"),
            ProfileItem(toolID: "terraform", provider: .homebrewFormula, packageName: "terraform", version: "1.13.3", tap: "hashicorp/tap"),
            ProfileItem(toolID: "codex", provider: .npm, packageName: "@openai/codex"),
            ProfileItem(toolID: "kimi-cli", provider: .uv, packageName: "kimi-cli"),
            ProfileItem(provider: .homebrewFormula, packageName: "-rf"),
            ProfileItem(provider: .homebrewFormula, packageName: "x", tap: "not-a-tap"),
            ProfileItem(provider: "mas", packageName: "497799835"),
        ])
        let diff = differ.diff(profile, snapshot: snapshot)
        let status = Dictionary(uniqueKeysWithValues: diff.entries.map { ($0.item.packageName, $0.status) })

        #expect(status["git"] == .installed(version: "2.52.0", provider: .homebrew))
        #expect(status["jq"] == .versionDiffers(installed: "1.6", expected: "1.7.1", provider: .homebrew))
        #expect(status["node"] == .installed(version: "24.1.0", provider: .nvm))
        #expect(status["postgresql@16"] == .installed(version: "17.6", provider: .homebrew))
        #expect(status["curl"] == .pending, "System-managed tools don't count")
        #expect(status["ffmpeg"] == .pending, "Unowned executables don't count")
        #expect(status["terraform"] == .installed(version: "1.13.3", provider: .homebrew))
        #expect(status["@openai/codex"] == .pending)
        #expect(status["kimi-cli"] == .unavailable(.providerMissing(.uv)))
        #expect(status["-rf"] == .unavailable(.invalidPackageName))
        #expect(status["x"] == .unavailable(.invalidPackageName))
        #expect(status["497799835"] == .unavailable(.unsupportedProvider("mas")))
        #expect(diff.entries.count == profile.items.count)
        #expect(diff.installed.count == 4 && diff.versionDiffers.count == 1 && diff.installable.count == 3 && diff.unavailable.count == 4)
    }

    @Test func waitsForPackageManagersAnEarlierStepInstalls() {
        let snapshot = RestoreFixture.snapshot(tools: [], available: [.homebrew])
        let template = try! #require(RestoreCatalog().template("ai-cli"))
        let diff = differ.diff(template.profile, snapshot: snapshot)
        let status = Dictionary(uniqueKeysWithValues: diff.entries.map { ($0.item.toolID?.rawValue ?? "", $0.status) })
        #expect(status["node"] == .pending)
        #expect(status["uv"] == .pending)
        #expect(status["claude-code"] == .pendingAfter(provider: .npm, enabledBy: ["node"]))
        #expect(status["aider"] == .pendingAfter(provider: .uv, enabledBy: ["uv"]))

        let noHomebrew = differ.diff(template.profile, snapshot: RestoreFixture.snapshot(tools: [], available: []))
        #expect(noHomebrew.entries.allSatisfy {
            if case let .unavailable(.providerMissing(provider)) = $0.status { return [.homebrew, .npm, .uv].contains(provider) }
            return false
        })
    }

    @Test func versionComparison() {
        #expect(ProfileDiffer.satisfies(installed: "8.5.10", expected: "8.5.7"))
        #expect(ProfileDiffer.satisfies(installed: "1.6.3_1", expected: "1.6.3"))
        #expect(!ProfileDiffer.satisfies(installed: "1.6.3", expected: "1.6.3_1"))
        #expect(ProfileDiffer.satisfies(installed: "HEAD", expected: "HEAD"))
        #expect(!ProfileDiffer.satisfies(installed: "HEAD", expected: "1.0"))
    }
}

@Suite("Restore staging")
struct RestorePlannerTests {
    private func item(_ tool: ToolID, _ provider: ProfileProvider, _ name: String) -> ProfileItem {
        ProfileItem(toolID: tool, provider: provider, packageName: name)
    }

    @Test func homebrewFirstThenProvidersItMakesAvailable() {
        let items = [
            item("cargo-nextest", .cargo, "cargo-nextest"),
            item("claude-code", .npm, "@anthropic-ai/claude-code"),
            item("pnpm", .npm, "pnpm"),
            item("x", .pnpm, "some-cli"),
            item("rust", .homebrewFormula, "rust"),
            item("node", .homebrewFormula, "node"),
            item("aider", .pipx, "aider-chat"),
            item("git", .homebrewFormula, "git"),
        ]
        let plan = RestorePlanner.stages(for: items) { $0 == .homebrew }
        #expect(plan.ready.map(\.provider) == [.homebrew])
        #expect(plan.ready.first?.items.map(\.packageName) == ["rust", "node", "git"])
        #expect(plan.deferred.map(\.provider) == [.npm, .pnpm, .cargo])
        #expect(plan.deferred.map(\.enabledBy) == [["node"], ["pnpm"], ["rust"]])
        #expect(plan.blocked.map(\.provider) == [.pipx])

        // After the Homebrew stage and its rescan, npm and cargo are available.
        let next = RestorePlanner.stages(for: items.filter { $0.provider != .homebrewFormula }) { [.homebrew, .npm, .cargo].contains($0) }
        #expect(next.ready.map(\.provider) == [.npm, .cargo])
        #expect(next.deferred.map(\.provider) == [.pnpm])
        #expect(next.blocked.map(\.provider) == [.pipx])
    }

    @Test func nothingDefersWithoutASelectedEnabler() {
        let plan = RestorePlanner.stages(for: [item("codex", .npm, "@openai/codex"), item("mas", "mas", "1")]) { _ in false }
        #expect(plan.ready.isEmpty && plan.deferred.isEmpty)
        #expect(plan.blocked.map(\.provider) == [.npm])
        #expect(plan.blocked.first?.requests == [InstallRequest(packageName: "@openai/codex", kind: .globalPackage, toolID: "codex")])
    }
}
