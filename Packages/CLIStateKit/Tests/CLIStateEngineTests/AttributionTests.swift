import CLIStateDomain
@testable import CLIStateEngine
import Foundation
import Testing

@Suite("AttributionEngine")
struct AttributionTests {
    let scenario = EngineScenario(path: [])

    private func engine(inventories: [ProviderInventory] = [], variables: [String: String] = [:]) -> AttributionEngine {
        AttributionEngine(fileSystem: scenario.fs, context: AttributionContext(homeDirectory: home, variables: variables, inventories: inventories))
    }

    @Test func systemLocationsIncludeCryptexesAndDeveloperDirectories() {
        let engine = engine()
        for path in [
            "/usr/bin/python3",
            "/System/Cryptexes/App/usr/bin/safari-cli",
            "/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin/tool",
            "/Library/Apple/usr/bin/tool",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/git",
        ] {
            let ownership = engine.attribute(name: "x", path: path, resolvedPath: path).ownership
            #expect(ownership.provider == .system, "\(path)")
            #expect(ownership.confidence == .confirmed)
        }
        #expect(engine.attribute(name: "x", path: "/usr/local/bin/x", resolvedPath: "/usr/local/bin/x").ownership.provider == .standalone)
        #expect(engine.attribute(name: "x", path: "/usr/libexecutables/x", resolvedPath: nil).ownership.provider == .standalone)
    }

    @Test func localBinAloneIsNeverEvidence() {
        let attribution = engine().attribute(name: "studio", path: "\(home)/.local/bin/studio", resolvedPath: "\(home)/.local/bin/studio")
        #expect(attribution.ownership.provider == .standalone)
        #expect(attribution.ownership.confidence == .unknown)
        #expect(attribution.ownership.evidence == [.pathDirectory("\(home)/.local/bin")])

        // uv's native layout needs the installer receipt, not just the directory (§37).
        #expect(engine().attribute(name: "uv", path: "\(home)/.local/bin/uv", resolvedPath: nil).ownership.provider == .standalone)
        scenario.fs.addFile("\(home)/.config/uv/uv-receipt.json")
        let withReceipt = engine().attribute(name: "uv", path: "\(home)/.local/bin/uv", resolvedPath: nil)
        #expect(withReceipt.ownership.provider == .native)
        #expect(withReceipt.ownership.confidence == .probable)
    }

    @Test func homebrewConfirmationNeedsInventoryAndSymlink() {
        let cellar = "/opt/homebrew/Cellar/php/8.5.7/bin/php"
        let without = engine().attribute(name: "php", path: "/opt/homebrew/bin/php", resolvedPath: cellar)
        #expect(without.ownership.provider == .homebrew)
        #expect(without.ownership.confidence == .probable)
        #expect(without.pathVersion == "8.5.7")

        let with = engine(inventories: [homebrewInventory([formula("php", "8.5.7")])]).attribute(name: "php", path: "/opt/homebrew/bin/php", resolvedPath: cellar)
        #expect(with.ownership.confidence == .confirmed)
        #expect(with.ownership.evidence == [.inventoryContains(provider: .homebrew, package: "php"), .symlinkResolvesInto("/opt/homebrew/Cellar/php")])
        #expect(with.installPrefix == "/opt/homebrew/Cellar/php/8.5.7")
    }

    @Test func versionManagersAreProbableWithVersions() {
        let engine = engine(variables: ["ASDF_DATA_DIR": "~/.asdf-data"])
        let nvm = engine.attribute(name: "node", path: "\(home)/.nvm/versions/node/v22.11.0/bin/node", resolvedPath: nil)
        #expect(nvm.ownership.provider == .nvm)
        #expect(nvm.ownership.confidence == .probable)
        #expect(nvm.pathVersion == "22.11.0")
        #expect(nvm.installPrefix == "\(home)/.nvm/versions/node/v22.11.0")

        let asdf = engine.attribute(name: "python3", path: "\(home)/.asdf-data/installs/python/3.12.4/bin/python3", resolvedPath: nil)
        #expect(asdf.ownership.provider == .asdf)
        #expect(asdf.pathVersion == "3.12.4")

        let pyenvShim = engine.attribute(name: "python3", path: "\(home)/.pyenv/shims/python3", resolvedPath: nil)
        #expect(pyenvShim.ownership.provider == .pyenv)
        #expect(pyenvShim.pathVersion == nil)
    }

    @Test func npmRootsRecordTheirNodeInstallation() {
        let scanned = engine(inventories: [npmInventory(root: "\(home)/.local/opt/node-v26.2.0-darwin-arm64/lib/node_modules", [npmPackage("@mimo-ai/cli", "0.1.0")])])
        let mimo = scanned.attribute(name: "mimo", path: "\(home)/.local/opt/node-v26.2.0-darwin-arm64/bin/mimo",
                                     resolvedPath: "\(home)/.local/opt/node-v26.2.0-darwin-arm64/lib/node_modules/@mimo-ai/cli/bin/mimo.js")
        #expect(mimo.ownership.provider == .npm)
        #expect(mimo.ownership.packageName == "@mimo-ai/cli")
        #expect(mimo.ownership.confidence == .confirmed)
        #expect(mimo.ownership.instance == ProviderInstanceID("npm@\(home)/.local/opt/node-v26.2.0-darwin-arm64/lib/node_modules"))

        // Not scanned, but inside Homebrew's prefix: still npm, tied to Homebrew's Node (F8).
        let brewNPM = engine().attribute(name: "npm", path: "/opt/homebrew/bin/npm", resolvedPath: "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js")
        #expect(brewNPM.ownership.provider == .npm)
        #expect(brewNPM.ownership.instance == "npm@/opt/homebrew/lib/node_modules")
        #expect(brewNPM.ownership.confidence == .probable)
        #expect(brewNPM.ownership.evidence.contains(.knownLayout("/opt/homebrew")))

        // A random vendored node_modules is not an npm global root.
        #expect(engine().attribute(name: "x", path: "/tmp/app/lib/node_modules/x/cli.js", resolvedPath: nil).ownership.provider == .standalone)
    }

    @Test func cargoRustupUvPipxAndAppBundles() {
        scenario.fs.addFile("\(home)/.cargo/bin/rustup", contents: Data(repeating: 1, count: 64), executable: true)
        scenario.fs.addFile("\(home)/.cargo/bin/rustc", contents: Data(repeating: 1, count: 64), executable: true)
        scenario.fs.addFile("\(home)/.cargo/bin/cargo-watch", contents: Data(repeating: 2, count: 32), executable: true)
        let engine = engine()
        #expect(engine.attribute(name: "rustc", path: "\(home)/.cargo/bin/rustc", resolvedPath: nil).ownership.provider == .rustup)
        #expect(engine.attribute(name: "cargo-watch", path: "\(home)/.cargo/bin/cargo-watch", resolvedPath: nil).ownership.provider == .cargo)

        let uv = engine.attribute(name: "kimi", path: "\(home)/.local/bin/kimi", resolvedPath: "\(home)/.local/share/uv/tools/kimi-cli/bin/kimi")
        #expect(uv.ownership.provider == .uv)
        #expect(uv.ownership.packageName == "kimi-cli")
        #expect(uv.ownership.confidence == .probable)

        let pipx = engine.attribute(name: "black", path: "\(home)/.local/bin/black", resolvedPath: "\(home)/.local/pipx/venvs/black/bin/black")
        #expect(pipx.ownership.provider == .pipx)

        let app = engine.attribute(name: "code", path: "/usr/local/bin/code", resolvedPath: "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
        #expect(app.ownership.provider == .appBundle)
        #expect(app.ownership.packageName == "Visual Studio Code.app")
    }

    @Test func brokenLinksUseTheirDestinationString() {
        let link = BrokenSymlink(path: "/opt/homebrew/bin/codexbar", destination: "../Caskroom/codexbar/0.56.4/CodexBar.app/Contents/Helpers/CodexBarCLI", pathPriority: 11)
        let attribution = engine().attribute(link)
        #expect(attribution.ownership.provider == .homebrew)
        #expect(attribution.ownership.packageName == "codexbar")
        #expect(attribution.packageKind == .cask)
        #expect(attribution.pathVersion == "0.56.4")
    }

    @Test func nativeConfirmationNeedsMatchingVersion() {
        let ownership = Ownership(provider: .native, confidence: .probable, evidence: [.knownLayout("\(home)/.local/share/claude/versions")])
        #expect(AttributionEngine.confirmingNative(ownership, pathVersion: "2.1.234", probedVersion: "2.1.200").confidence == .probable)
        let confirmed = AttributionEngine.confirmingNative(ownership, pathVersion: "2.1.234", probedVersion: "v2.1.234")
        #expect(confirmed.confidence == .confirmed)
        #expect(confirmed.evidence.last == .versionMatches("2.1.234"))
        let noLayout = Ownership(provider: .native, confidence: .probable, evidence: [.pathDirectory("/x")])
        #expect(AttributionEngine.confirmingNative(noLayout, pathVersion: "1.0", probedVersion: "1.0").confidence == .probable)
    }
}
