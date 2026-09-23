import CLIStateDomain
import Foundation
import Testing
@testable import CLIStateAI

@Suite("AI prompt builder")
struct AIPromptBuilderTests {
    static let home = "/Users/alice"
    static let at = Date(timeIntervalSince1970: 1_800_000_000)

    static func observed(_ version: String) -> ObservedValue<ToolVersion> {
        ObservedValue(ToolVersion(version), source: .inferred, confidence: .confirmed, observedAt: at)
    }

    /// Node.js: a standalone binary in ~/.local/bin shadows Homebrew's.
    static var node: Tool {
        let standalone = ToolInstallation(
            id: .path("\(home)/.local/bin/node"),
            ownership: Ownership(provider: .standalone, confidence: .unknown, evidence: [.pathDirectory("\(home)/.local/bin")]),
            version: observed("26.2.0"),
            executables: [ExecutableRef(name: "node", path: "\(home)/.local/bin/node", pathPriority: 10, architecture: .arm64)],
            linkState: .active
        )
        let brew = ToolInstallation(
            id: .package(provider: .homebrew, name: "node"),
            ownership: Ownership(provider: .homebrew, packageName: "node", confidence: .confirmed, evidence: [.knownLayout("/opt/homebrew/Cellar/node")]),
            version: observed("26.7.0"),
            latest: observed("26.8.2"),
            executables: [
                ExecutableRef(name: "node", path: "/opt/homebrew/bin/node", resolvedPath: "/opt/homebrew/Cellar/node/26.7.0/bin/node", pathPriority: 11, architecture: .arm64),
                ExecutableRef(name: "npx", path: "/opt/homebrew/bin/npx", pathPriority: 11),
            ],
            installPrefix: "/opt/homebrew/Cellar/node/26.7.0",
            linkState: .shadowed,
            isDirect: true,
            dependencies: ["brotli", "icu4c@77", "libuv"],
            dependents: ["yarn"],
            configPaths: ["\(home)/.npmrc"]
        )
        let chain = [standalone.executables[0], brew.executables[0]]
        return Tool(
            id: "node",
            identity: ToolIdentity(name: "node", displayName: "Node.js", summary: "JavaScript runtime built on V8", category: .runtime, homepage: URL(string: "https://nodejs.org"), registryID: "node"),
            installations: [standalone, brew],
            activeInstallationID: standalone.id,
            resolution: CommandResolution(command: "node", chain: chain, shadows: [ShellShadow(name: "node", kind: .alias, detail: "node --secret-token=abc123 \(home)/bin")]),
            health: ToolHealthState(status: .pathConflict, issueIDs: ["pathConflict:node"]),
            lastScannedAt: at
        )
    }

    let builder = AIPromptBuilder(homeDirectory: home, userName: "alice", language: .simplifiedChinese)

    @Test func toolPromptContainsTheFacts() {
        let prompt = builder.request(for: .tool(Self.node)).prompt
        #expect(prompt.contains("Tool: Node.js"))
        #expect(prompt.contains("Category: language runtime"))
        #expect(prompt.contains("Installed via standalone"))
        #expect(prompt.contains("Installed via homebrew"))
        #expect(prompt.contains("Package: node"))
        #expect(prompt.contains("Version: 26.7.0"))
        #expect(prompt.contains("Newer version available: 26.8.2"))
        #expect(prompt.contains("How sure CLI State is about the installer: unknown"))
        #expect(prompt.contains("this is the one Terminal runs"))
        #expect(prompt.contains("shadowed"))
        #expect(prompt.contains("Commands: node, npx"))
        #expect(prompt.contains("Needed by: yarn"))
        #expect(prompt.contains("Terminal runs: ~/.local/bin/node"))
    }

    @Test func promptIsRedacted() {
        let preview = builder.payloadPreview(for: .tool(Self.node))
        #expect(!preview.contains("/Users/alice"))
        #expect(!preview.contains("alice"))
        #expect(preview.contains("~/.local/bin/node"))
        // Alias bodies, config files and evidence never leave the Mac.
        #expect(!preview.contains("secret-token"))
        #expect(!preview.contains(".npmrc"))
        #expect(preview.contains("Shell definitions with the same name run first: alias"))
    }

    @Test func redactionHandlesEdgeCases() {
        let builder = AIPromptBuilder(homeDirectory: "/Users/al", userName: "al", language: .english)
        #expect(builder.redact("/Users/al/bin/x") == "~/bin/x")
        #expect(builder.redact("/Users/al") == "~")
        #expect(builder.redact("/Users/alex/bin/x") == "/Users/<user>/bin/x")
        #expect(builder.redact("/Users/Shared/tool, /Users/bob/.cargo/bin") == "/Users/Shared/tool, /Users/<user>/.cargo/bin")
        #expect(builder.redact("owner al; package pal-tools") == "owner <user>; package pal-tools")
    }

    @Test func noEnvironmentEvenWhenPresentElsewhere() {
        // The builder only sees `Tool`/`HealthIssue`; make sure nothing env-like sneaks into the instructions.
        let preview = builder.payloadPreview(for: .tool(Self.node))
        for marker in ["PATH=", "HOME=", "HOMEBREW_", "export ", "OPENAI_API_KEY"] {
            #expect(!preview.contains(marker))
        }
    }

    @Test func instructionsFollowAnswerLanguage() {
        let chinese = builder.request(for: .tool(Self.node))
        #expect(chinese.language == .simplifiedChinese)
        #expect(chinese.instructions.contains("Simplified Chinese"))
        let english = AIPromptBuilder(homeDirectory: Self.home, userName: "alice", language: .english).request(for: .tool(Self.node))
        #expect(english.instructions.contains("Write the whole answer in English"))
        #expect(english.instructions.contains("Can I remove it?"))
    }

    @Test func instructionsUseSuppliedHeadingsAndTerms() {
        var vocabulary = AIPromptVocabulary.english
        vocabulary.whatItIs = "它是什么"
        vocabulary.terms = ["shadowed": "被遮蔽", "active": "生效中"]
        let builder = AIPromptBuilder(homeDirectory: Self.home, userName: "alice", language: .simplifiedChinese, vocabulary: vocabulary)
        let instructions = builder.request(for: .tool(Self.node)).instructions
        #expect(instructions.contains("## 它是什么\n"))
        #expect(instructions.contains("## What it's used for\n"))
        #expect(!instructions.contains("## 1."))
        #expect(instructions.contains("use the app's word instead of the English one"))
        let prompt = builder.request(for: .tool(Self.node)).prompt
        #expect(prompt.contains("Link state: shadowed (\"被遮蔽\" in the app; an earlier PATH entry wins)"))
        #expect(prompt.contains("Link state: active (\"生效中\" in the app), this is the one Terminal runs"))
    }

    @Test func issuePromptUsesAllowlistedDetails() {
        let issue = HealthIssue(
            type: .shellShadowing, severity: .info, subject: "node", toolID: "node",
            paths: ["/Users/alice/.local/bin/node", "/opt/homebrew/bin/node"],
            details: ["detail": "alias node='node --token=abc'", "providers": "standalone,homebrew", "reason": "brew: error at /Users/alice/x"]
        )
        let request = builder.request(for: .issue(issue, relatedTool: Self.node))
        #expect(request.prompt.contains("Issue type: shellShadowing"))
        #expect(request.prompt.contains("providers: standalone,homebrew"))
        #expect(request.prompt.contains("Paths: ~/.local/bin/node, /opt/homebrew/bin/node"))
        #expect(request.prompt.contains("Related tool: Node.js"))
        #expect(!request.prompt.contains("token"))
        #expect(!request.prompt.contains("brew: error"))
        #expect(!request.prompt.contains("alice"))
        #expect(request.instructions.contains("How to fix it"))
    }

    @Test func largeToolsAreTruncated() {
        var tool = Self.node
        let template = tool.installations[1]
        tool.installations = (0..<20).map { index in
            var copy = template
            copy.id = InstallationID("homebrew:node@\(index)")
            copy.dependencies = (0..<50).map { "dep\($0)" }
            return copy
        }
        let prompt = builder.request(for: .tool(tool)).prompt
        #expect(prompt.contains("Installations (20):"))
        #expect(prompt.contains("14 more not listed"))
        #expect(prompt.contains("and 42 more"))
        #expect(prompt.count < 8_000)
    }
}
