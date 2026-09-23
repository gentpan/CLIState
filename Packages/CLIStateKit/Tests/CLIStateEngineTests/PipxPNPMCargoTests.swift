import CLIStateDomain
@testable import CLIStateEngine
import CLIStateTestSupport
import Foundation
import Testing

@Suite("pipx, pnpm and Cargo")
struct PipxPNPMCargoTests {
    // MARK: Provider state

    @Test func providerSnapshotsIncludePipxPnpmAndCargo() async throws {
        let scenario = EngineScenario()
        let snapshot = await scenario.build(inventories: [
            cargoInventory([crate("deepseek-tui", "0.8.20", bins: ["deepseek-tui"])]),
            pnpmInventory([]),
            ProviderInventory(providerID: .pipx, availability: .unavailable(.pipx, reason: "executableNotFound"), depth: .fast, scannedAt: scanDate),
        ])
        let providers = Dictionary(uniqueKeysWithValues: snapshot.providers.map { ($0.providerID, $0) })
        #expect(snapshot.providers.map(\.providerID) == [.cargo, .pipx, .pnpm])
        #expect(providers[.cargo]?.toolCount == 1)
        #expect(providers[.cargo]?.layout[.cargoBin] == "\(home)/.cargo/bin")
        #expect(providers[.cargo]?.freshness == .fresh(scanDate))
        #expect(providers[.pnpm]?.availability.isAvailable == true)
        #expect(providers[.pipx]?.freshness == .unavailable)
    }

    // MARK: Cargo

    /// Real shape (2026-09-13): `cargo install --list` reports `deepseek-tui v0.8.20` (bin
    /// `deepseek-tui`) and `deepseek-tui-cli v0.8.20` (bin `deepseek`); cargo is Homebrew's.
    @Test func cargoBinariesListedByCargoAreConfirmed() async throws {
        let scenario = EngineScenario()
        let bin = "\(home)/.cargo/bin"
        scenario.binary("\(bin)/deepseek-tui", header: MachOHeader.arm64)
        scenario.binary("\(bin)/deepseek", header: MachOHeader.arm64)
        scenario.binary("\(bin)/rg", header: MachOHeader.arm64)
        scenario.binary("\(bin)/local-tool", header: MachOHeader.arm64)
        scenario.binary("\(bin)/cargo-watch", header: MachOHeader.arm64)
        // rustup proxies are hard links of rustup; `cargo install --list` never lists them.
        scenario.fs.addFile("\(bin)/rustup", contents: Data(repeating: 1, count: 64), executable: true)
        scenario.fs.addFile("\(bin)/rustc", contents: Data(repeating: 1, count: 64), executable: true)
        scenario.fs.addFile("\(home)/.cargo/.crates2.json", contents: crates2JSON)

        let inventory = cargoInventory([
            crate("deepseek-tui", "0.8.20", bins: ["deepseek-tui"]),
            crate("deepseek-tui-cli", "0.8.20", bins: ["deepseek"]),
            crate("ripgrep", "14.1.1", bins: ["rg"]),
            crate("local-tool", "0.1.0", bins: ["local-tool"], pinned: true),
        ])
        let snapshot = await scenario.build(inventories: [inventory])

        let tui = try #require(snapshot.tool("cargo.deepseek-tui")?.installation("cargo:deepseek-tui"))
        #expect(tui.ownership == Ownership(provider: .cargo, packageName: "deepseek-tui", confidence: .confirmed, evidence: [
            .inventoryContains(provider: .cargo, package: "deepseek-tui"), .knownLayout(bin), .knownLayout("\(home)/.cargo/.crates2.json"),
        ]))
        #expect(tui.version?.value.rawValue == "0.8.20")
        #expect(tui.version?.source == .provider(.cargo))
        #expect(tui.linkState == .active)
        #expect(tui.executables.map(\.path) == ["\(bin)/deepseek-tui"])
        #expect(tui.capabilities == ToolCapabilities(canUpdate: true, canUninstall: true))

        let cli = try #require(snapshot.tool("cargo.deepseek-tui-cli"))
        #expect(cli.resolution?.command == "deepseek")
        #expect(cli.installation("cargo:deepseek-tui-cli")?.ownership.confidence == .confirmed)

        let ripgrep = try #require(snapshot.tool("ripgrep")?.installation("cargo:ripgrep"))
        #expect(ripgrep.ownership.confidence == .confirmed)
        #expect(ripgrep.capabilities.canUpdate && ripgrep.capabilities.canUninstall)
        #expect(ripgrep.executables.map(\.name) == ["rg"])

        let pinned = try #require(snapshot.tool("cargo.local-tool")?.installation("cargo:local-tool"))
        #expect(pinned.ownership.confidence == .confirmed)
        #expect(pinned.capabilities == ToolCapabilities(canUninstall: true), "git/path crates: uninstall only")

        let rustc = snapshot.tools.flatMap(\.installations).filter { $0.executables.contains { $0.path == "\(bin)/rustc" } }
        #expect(rustc.map(\.ownership.provider) == [.rustup])

        let unlisted = try #require(snapshot.tool("cargo.cargo-watch")?.installations.first)
        #expect(unlisted.ownership == Ownership(provider: .cargo, confidence: .probable, evidence: [.knownLayout(bin)]))
        #expect(unlisted.capabilities == .none)
    }

    @Test func cargoMetadataNamesCratesWhenCargoIsNotScanned() async throws {
        let scenario = EngineScenario()
        scenario.binary("\(home)/.cargo/bin/deepseek", header: MachOHeader.arm64)
        scenario.fs.addFile("\(home)/.cargo/.crates2.json", contents: crates2JSON)

        let snapshot = await scenario.build()
        let tool = try #require(snapshot.tool("cargo.deepseek-tui-cli"))
        let installation = try #require(tool.installations.first)
        #expect(installation.id == "cargo:deepseek-tui-cli", "same id as when cargo lists it")
        #expect(installation.ownership.confidence == .probable)
        #expect(installation.version?.value.rawValue == "0.8.20")
        #expect(installation.version?.source == .filesystem)
        #expect(installation.capabilities == .none)
    }

    @Test func parsesCargoInstallMetadata() {
        let metadata = CargoInstallMetadata.parse(crates2JSON)
        #expect(metadata.installsByBinary["deepseek"] == CargoInstallMetadata.Install(crate: "deepseek-tui-cli", version: "0.8.20"))
        #expect(metadata.installsByBinary["deepseek-tui"]?.crate == "deepseek-tui")
        #expect(CargoInstallMetadata.parse(Data("not json".utf8)).installsByBinary.isEmpty)
        #expect(CargoInstallMetadata.parse(Data(#"{"installs":{"broken":{"bins":["x"]},"ok 1.0.0 (path+file:///x)":{"bins":"x"}}}"#.utf8)).installsByBinary.isEmpty)
    }

    @Test func staleCargoInventoryKeepsConfirmationAndPins() async throws {
        let scenario = EngineScenario()
        scenario.binary("\(home)/.cargo/bin/deepseek-tui", header: MachOHeader.arm64)
        scenario.binary("\(home)/.cargo/bin/local-tool", header: MachOHeader.arm64)
        let inventory = cargoInventory([
            crate("deepseek-tui", "0.8.20", bins: ["deepseek-tui"]),
            crate("local-tool", "0.1.0", bins: ["local-tool"], pinned: true),
        ])
        let first = await scenario.build(inventories: [inventory])
        let stale = await scenario.build(failed: [.cargo: "timeout"], previous: first)

        #expect(stale.providers.first { $0.providerID == .cargo }?.freshness == .stale(scanDate))
        #expect(stale.tool("cargo.deepseek-tui")?.installations.first?.capabilities == ToolCapabilities(canUpdate: true, canUninstall: true))
        #expect(stale.tool("cargo.local-tool")?.installations.first?.capabilities == ToolCapabilities(canUninstall: true))
    }

    // MARK: pipx

    @Test func pipxVenvsListedByPipxAreConfirmed() async throws {
        let scenario = EngineScenario()
        let venvs = "\(home)/custom/pipx/venvs"
        for (package, app) in [("aider-chat", "aider"), ("black", "black"), ("ghost", "ghost")] {
            scenario.executable("\(venvs)/\(package)/bin/\(app)")
            scenario.link("\(home)/.local/bin/\(app)", to: "\(venvs)/\(package)/bin/\(app)")
        }
        let inventory = ProviderInventory(
            providerID: .pipx,
            availability: ProviderAvailability(providerID: .pipx, isAvailable: true, executable: "/opt/homebrew/bin/pipx", version: "1.8.0"),
            layout: ProviderLayout(roots: [.pipxVenvs: venvs, .pipxBinDir: "\(home)/.local/bin"]),
            tools: [
                pipxVenv("aider-chat", "0.86.1", apps: ["aider"], venvs: venvs),
                pipxVenv("black", "25.1.0", apps: ["black"], venvs: venvs, pinned: true),
            ],
            depth: .fast,
            scannedAt: scanDate
        )
        let snapshot = await scenario.build(inventories: [inventory])

        let aider = try #require(snapshot.tool("aider")?.installation("pipx:aider-chat"))
        #expect(aider.ownership.confidence == .confirmed)
        #expect(aider.ownership.evidence == [.inventoryContains(provider: .pipx, package: "aider-chat"), .symlinkResolvesInto("\(venvs)/aider-chat")])
        #expect(aider.linkState == .active)
        #expect(aider.version?.value.rawValue == "0.86.1")
        #expect(aider.capabilities.canUpdate && aider.capabilities.canUninstall)

        let black = try #require(snapshot.tool("pipx.black")?.installation("pipx:black"))
        #expect(black.ownership.confidence == .confirmed)
        #expect(black.capabilities == ToolCapabilities(canUninstall: true), "pinned venv")

        // A venv pipx does not list is not confirmed.
        let ghost = try #require(snapshot.tool("pipx.ghost")?.installations.first)
        #expect(ghost.ownership.confidence == .probable)
        #expect(ghost.capabilities == .none)
    }

    // MARK: pnpm

    @Test func pnpmShimsListedByPnpmAreConfirmed() async throws {
        let pnpmHome = "\(home)/Library/pnpm"
        let scenario = EngineScenario(path: referencePATH + [pnpmHome])
        for shim in ["tsc", "tsserver", "pnpm", "local-cli", "stray"] {
            scenario.executable("\(pnpmHome)/\(shim)", contents: "#!/bin/sh\nexec node \"$basedir/global/5/node_modules/x/bin/\(shim)\" \"$@\"\n")
        }
        let npmRoot = "\(home)/.local/opt/node-v26.2.0-darwin-arm64/lib/node_modules"
        let snapshot = await scenario.build(inventories: [
            pnpmInventory([
                pnpmPackage("typescript", "5.9.2", bins: ["tsc", "tsserver"]),
                pnpmPackage("pnpm", "10.33.0", bins: ["pnpm"]),
                pnpmPackage("local-cli", nil, bins: ["local-cli"], pinned: true),
            ]),
            npmInventory(root: npmRoot, [npmPackage("typescript", "5.8.3", executables: ["tsc", "tsserver"])]),
        ])

        // Same package from npm and pnpm: one tool in the npm namespace.
        let typescript = try #require(snapshot.tool("npm.typescript"))
        #expect(typescript.installations.map(\.id) == ["pnpm:typescript", "npm@\(npmRoot):typescript"])
        let viaPNPM = try #require(typescript.installation("pnpm:typescript"))
        #expect(viaPNPM.ownership == Ownership(provider: .pnpm, packageName: "typescript", confidence: .confirmed, evidence: [
            .inventoryContains(provider: .pnpm, package: "typescript"), .knownLayout(pnpmHome),
        ]))
        #expect(viaPNPM.executables.map(\.name) == ["tsc", "tsserver"])
        #expect(viaPNPM.version?.value.rawValue == "5.9.2")
        #expect(viaPNPM.linkState == .active)
        #expect(viaPNPM.capabilities == ToolCapabilities(canUpdate: true, canUninstall: true))
        #expect(typescript.activeInstallationID == "pnpm:typescript")

        let pnpm = try #require(snapshot.tool("pnpm")?.installation("pnpm:pnpm"))
        #expect(pnpm.ownership.confidence == .confirmed)

        let linked = try #require(snapshot.tool("npm.local-cli")?.installation("pnpm:local-cli"))
        #expect(linked.capabilities == ToolCapabilities(canUninstall: true), "link: packages")

        let stray = try #require(snapshot.tools.first { $0.identity.name == "stray" })
        #expect(stray.identity.category == .unrecognized)
        #expect(!scenario.runner.invocations.contains { $0.command.executable.hasPrefix(pnpmHome) })
    }

    // MARK: bun

    @Test func bunGlobalPackageVersionComesFromItsPackageJSON() async throws {
        let scenario = EngineScenario()
        let package = "\(home)/.bun/install/global/node_modules/@opencode-ai/cli"
        scenario.executable("\(package)/bin/opencode2")
        scenario.fs.addFile("\(package)/package.json", contents: Data(#"{"name":"@opencode-ai/cli","version":"0.0.0-next-15329","bin":{"opencode2":"./bin/opencode2"}}"#.utf8))
        scenario.link("\(home)/.bun/bin/opencode2", to: "\(package)/bin/opencode2")

        let snapshot = await scenario.build()
        let installation = try #require(snapshot.tool("npm.@opencode-ai/cli")?.installation("bun:@opencode-ai/cli"))
        #expect(installation.version == ObservedValue(ToolVersion("0.0.0-next-15329"), source: .filesystem, confidence: .probable, observedAt: scanDate))

        scenario.fs.addFile("\(package)/package.json", contents: Data(#"{"name":"something-else","version":"9.9.9"}"#.utf8))
        #expect(PackageManifest.version(packageDirectory: package, expectedName: "@opencode-ai/cli", fileSystem: scenario.fs) == nil)
        scenario.fs.addFile("\(package)/package.json", contents: Data("{".utf8))
        #expect(PackageManifest.version(packageDirectory: package, expectedName: "@opencode-ai/cli", fileSystem: scenario.fs) == nil)
    }

    // MARK: Registry

    @Test func registryPackagesFromTheNewProviders() {
        let registry = ToolRegistry.standard
        #expect(registry.definition(forPackage: "ripgrep", provider: .cargo)?.id == "ripgrep")
        #expect(registry.definition(forPackage: "deno", provider: .cargo)?.id == "deno")
        #expect(registry.definition(forPackage: "aider-chat", provider: .pipx)?.id == "aider")
        #expect(registry.definition(forPackage: "kimi-cli", provider: .pipx)?.id == "kimi-cli")
        #expect(registry.definition(forPackage: "uv", provider: .pipx)?.id == "uv")
        #expect(registry.definition(forPackage: "pnpm", provider: .pnpm)?.id == "pnpm")
        #expect(registry.definition(forPackage: "deepseek-tui", provider: .cargo) == nil)
    }
}

// MARK: - Builders

private let crates2JSON = Data(#"""
{"installs":{"deepseek-tui 0.8.20 (registry+https://github.com/rust-lang/crates.io-index)":{"version_req":null,"bins":["deepseek-tui"],"features":[],"profile":"release"},"deepseek-tui-cli 0.8.20 (registry+https://github.com/rust-lang/crates.io-index)":{"version_req":null,"bins":["deepseek"],"features":[],"profile":"release"}}}
"""#.utf8)

private func cargoInventory(_ tools: [ProviderTool]) -> ProviderInventory {
    let bin = "\(home)/.cargo/bin"
    return ProviderInventory(
        providerID: .cargo,
        availability: ProviderAvailability(providerID: .cargo, isAvailable: true, executable: "/opt/homebrew/bin/cargo", version: "1.95.0"),
        layout: ProviderLayout(roots: [.cargoHome: "\(home)/.cargo", .cargoBin: bin]),
        tools: tools,
        depth: .fast,
        scannedAt: scanDate
    )
}

private func crate(_ name: String, _ version: String, bins: [String], pinned: Bool = false) -> ProviderTool {
    let bin = "\(home)/.cargo/bin"
    return ProviderTool(
        providerID: .cargo, packageName: name, kind: .tool, installedVersions: [version], activeVersion: version,
        isPinned: pinned, installPrefix: bin, executableNames: bins, executablePaths: bins.map { "\(bin)/\($0)" }, isDirect: true
    )
}

private func pipxVenv(_ name: String, _ version: String, apps: [String], venvs: String, pinned: Bool = false) -> ProviderTool {
    ProviderTool(
        providerID: .pipx, packageName: name, kind: .tool, installedVersions: [version], activeVersion: version, isPinned: pinned,
        installPrefix: "\(venvs)/\(name)", executableNames: apps, executablePaths: apps.map { "\(home)/.local/bin/\($0)" }, isDirect: true
    )
}

private let pnpmRoot = "\(home)/Library/pnpm/global/5/node_modules"

private func pnpmInventory(_ tools: [ProviderTool]) -> ProviderInventory {
    ProviderInventory(
        providerID: .pnpm,
        availability: ProviderAvailability(providerID: .pnpm, isAvailable: true, executable: "\(home)/Library/pnpm/pnpm", version: "10.33.0"),
        layout: ProviderLayout(roots: [.pnpmGlobalRoot: pnpmRoot, .pnpmGlobalBin: "\(home)/Library/pnpm"]),
        tools: tools,
        depth: .fast,
        scannedAt: scanDate
    )
}

private func pnpmPackage(_ name: String, _ version: String?, bins: [String], pinned: Bool = false) -> ProviderTool {
    ProviderTool(
        providerID: .pnpm, packageName: name, kind: .globalPackage, installedVersions: version.map { [$0] } ?? [], activeVersion: version,
        isPinned: pinned, installPrefix: "\(pnpmRoot)/\(name)", executableNames: bins,
        executablePaths: bins.map { "\(home)/Library/pnpm/\($0)" }, isDirect: true
    )
}
