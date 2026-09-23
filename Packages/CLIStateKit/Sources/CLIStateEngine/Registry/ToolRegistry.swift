import CLIStateDomain
import Foundation

/// Lookup over tool definitions. Earlier definitions win when two claim the same
/// executable or package name.
public struct ToolRegistry: Sendable {
    public let definitions: [ToolDefinition]
    private let byID: [ToolID: ToolDefinition]
    private let byExecutable: [String: ToolID]
    private let byPackage: [ProviderID: [String: ToolID]]

    public init(definitions: [ToolDefinition]) {
        self.definitions = definitions
        var byID: [ToolID: ToolDefinition] = [:]
        var byExecutable: [String: ToolID] = [:]
        var byPackage: [ProviderID: [String: ToolID]] = [:]
        for definition in definitions where byID[definition.id] == nil {
            byID[definition.id] = definition
            for name in definition.executables where byExecutable[name] == nil {
                byExecutable[name] = definition.id
            }
            for (provider, names) in definition.packages {
                for name in names where byPackage[provider, default: [:]][name] == nil {
                    byPackage[provider, default: [:]][name] = definition.id
                }
            }
        }
        self.byID = byID
        self.byExecutable = byExecutable
        self.byPackage = byPackage
    }

    public static let standard = ToolRegistry(definitions: StandardDefinitions.all)

    public func definition(_ id: ToolID) -> ToolDefinition? { byID[id] }

    public func definition(forExecutable name: String) -> ToolDefinition? {
        byExecutable[name].flatMap { byID[$0] }
    }

    /// Matches a provider package to a registry tool. Homebrew: `php@8.2` → `php`,
    /// `mongodb/brew/mongodb-community` → `mongodb`. pnpm and bun install npm registry
    /// packages, so they fall back to the npm names.
    public func definition(forPackage name: String, provider: ProviderID) -> ToolDefinition? {
        let providers = provider == .pnpm || provider == .bun ? [provider, .npm] : [provider]
        for provider in providers {
            guard let table = byPackage[provider] else { continue }
            for candidate in Self.packageNameVariants(name, provider: provider) {
                if let id = table[candidate] { return byID[id] }
            }
        }
        return nil
    }

    /// Every command name, for `whence -wa` shell-shadow detection (F4).
    /// Constants only, never user input (§105.2).
    public var commandNames: [String] {
        Array(Set(definitions.flatMap(\.executables))).sorted()
    }

    static func packageNameVariants(_ name: String, provider: ProviderID) -> [String] {
        guard provider == .homebrew else { return [name] }
        let short = PathUtil.lastComponent(name)
        var variants = [name, short]
        if let at = short.firstIndex(of: "@"), at != short.startIndex {
            variants.append(String(short[..<at]))
        }
        return variants.uniqued()
    }
}
