import CLIStateDomain
import Foundation

/// Installable registry tools and curated templates (Lane N). Every template item
/// references a registry tool and one of its registry package names, so a
/// template can never ask a package manager for something the registry doesn't know.
public struct RestoreCatalog: Sendable {
    public let registry: ToolRegistry

    public init(registry: ToolRegistry = .standard) {
        self.registry = registry
    }

    /// Providers CLIState can install with, in the order a plan runs them.
    public static let installOrder: [ProviderID] = [.homebrew, .npm, .pnpm, .uv, .pipx, .cargo]

    /// Homebrew first; AI CLIs ship through npm (or uv/pipx) first, since their
    /// Homebrew entries are often casks or lag behind.
    static func preference(for category: ToolCategory) -> [ProviderID] {
        category == .aiCLI ? [.npm, .uv, .pipx, .homebrew, .pnpm, .cargo] : [.homebrew, .npm, .uv, .pipx, .cargo, .pnpm]
    }

    /// The profile item for a registry tool, through `provider` when given.
    public func item(for toolID: ToolID, provider: ProviderID? = nil, cask: Bool = false) -> ProfileItem? {
        guard let definition = registry.definition(toolID) else { return nil }
        let providers = provider.map { [$0] } ?? Self.preference(for: definition.category)
        for providerID in providers {
            guard let name = definition.packages[providerID]?.first,
                  let profileProvider = ProfileProvider(providerID: providerID, kind: Self.kind(for: providerID, cask: cask))
            else { continue }
            let (tap, short) = Self.splitTap(name, provider: providerID)
            return ProfileItem(toolID: definition.id, provider: profileProvider, packageName: short, tap: tap)
        }
        return nil
    }

    static func kind(for provider: ProviderID, cask: Bool) -> PackageKind {
        switch provider {
        case .homebrew: cask ? .cask : .formula
        case .npm, .pnpm: .globalPackage
        default: .tool
        }
    }

    /// `hashicorp/tap/terraform` → (`hashicorp/tap`, `terraform`).
    static func splitTap(_ name: String, provider: ProviderID) -> (tap: String?, name: String) {
        guard provider == .homebrew else { return (nil, name) }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return (nil, name) }
        return ("\(parts[0])/\(parts[1])", String(parts[2]))
    }

    /// Whitelist for AI suggestions: every registry tool with an installable package.
    public var candidates: [RestoreCandidate] {
        registry.definitions.compactMap { definition in
            item(for: definition.id).map {
                RestoreCandidate(toolID: definition.id, displayName: definition.displayName, summary: definition.summary, category: definition.category, item: $0)
            }
        }
    }

    // MARK: Templates

    struct TemplateSpec: Sendable {
        var id: String
        /// Tool plus an optional provider override when it isn't the preferred one.
        var tools: [(ToolID, ProviderID?)]
    }

    static let specs: [TemplateSpec] = [
        TemplateSpec(id: "frontend-web", tools: [
            ("git", nil), ("gh", nil), ("node", nil), ("pnpm", nil), ("yarn", nil), ("deno", nil),
        ]),
        TemplateSpec(id: "node-fullstack", tools: [
            ("git", nil), ("gh", nil), ("node", nil), ("pnpm", nil), ("postgresql", nil), ("redis", nil), ("jq", nil),
        ]),
        TemplateSpec(id: "python-data", tools: [
            ("git", nil), ("python", nil), ("uv", nil), ("ruff", nil), ("jupyterlab", .uv), ("duckdb", nil), ("sqlite", nil),
        ]),
        TemplateSpec(id: "php-laravel", tools: [
            ("git", nil), ("php", nil), ("composer", nil), ("node", nil), ("mysql", nil), ("redis", nil), ("nginx", nil),
        ]),
        TemplateSpec(id: "go-backend", tools: [
            ("git", nil), ("gh", nil), ("go", nil), ("gopls", nil), ("golangci-lint", nil), ("postgresql", nil), ("redis", nil),
        ]),
        TemplateSpec(id: "rust", tools: [
            ("git", nil), ("rust", nil), ("rust-analyzer", nil), ("cargo-nextest", .cargo), ("ripgrep", nil),
        ]),
        TemplateSpec(id: "apple-platforms", tools: [
            ("git", nil), ("xcodes", nil), ("swiftlint", nil), ("swiftformat", nil), ("xcbeautify", nil), ("cocoapods", nil), ("fastlane", nil),
        ]),
        TemplateSpec(id: "ai-cli", tools: [
            ("node", nil), ("uv", nil), ("claude-code", nil), ("codex", nil), ("gemini-cli", nil), ("opencode", nil), ("aider", .uv),
        ]),
        TemplateSpec(id: "devops-cloud", tools: [
            ("git", nil), ("jq", nil), ("kubectl", nil), ("helm", nil), ("k9s", nil), ("terraform", nil), ("awscli", nil),
        ]),
    ]

    /// Every template, with items resolved against the registry. A spec entry the
    /// registry can't resolve is left out (the integrity test fails on it).
    public var templates: [EnvironmentTemplate] {
        Self.specs.map { spec in
            EnvironmentTemplate(id: spec.id, items: spec.tools.compactMap { item(for: $0.0, provider: $0.1) })
        }
    }

    public func template(_ id: String) -> EnvironmentTemplate? {
        templates.first { $0.id == id }
    }

    /// Template tool IDs as written, for the integrity test.
    static var specToolIDs: [(template: String, tool: ToolID, provider: ProviderID?)] {
        specs.flatMap { spec in spec.tools.map { (spec.id, $0.0, $0.1) } }
    }
}
