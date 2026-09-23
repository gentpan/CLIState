import CLIStateDomain
import Foundation

/// How a tool maps to an endoflife.date product.
public struct EndOfLifeDefinition: Hashable, Sendable {
    public enum CycleScheme: Hashable, Sendable {
        /// `22.3.0` → `22`.
        case major
        /// `3.9.18` → `3.9`.
        case majorMinor
        /// `major.minor` when the product lists it, else `major` (PostgreSQL `9.6` vs `14`, Deno `1` vs `2.4`).
        case automatic
        /// Java: `1.8.0_392` → `8`, `21.0.2` → `21`.
        case javaFeature
    }

    /// Slug, e.g. `nodejs`.
    public var product: String
    public var scheme: CycleScheme
    /// When set, only installations whose prefix or resolved executable path contains
    /// one of these (case-insensitive) match — a vendor-specific product such as
    /// Eclipse Temurin must not be applied to every JDK.
    public var pathHints: [String]

    public init(product: String, scheme: CycleScheme, pathHints: [String] = []) {
        self.product = product
        self.scheme = scheme
        self.pathHints = pathHints
    }
}

extension StandardDefinitions {
    /// Runtimes and databases whose release cycles endoflife.date tracks. Tools not
    /// listed (Rust ships every six weeks, SQLite has one open cycle) get no reminder.
    static let endOfLifeProducts: [ToolID: EndOfLifeDefinition] = [
        "node": EndOfLifeDefinition(product: "nodejs", scheme: .major),
        "python": EndOfLifeDefinition(product: "python", scheme: .majorMinor),
        "php": EndOfLifeDefinition(product: "php", scheme: .majorMinor),
        "go": EndOfLifeDefinition(product: "go", scheme: .majorMinor),
        "ruby": EndOfLifeDefinition(product: "ruby", scheme: .majorMinor),
        // Only Temurin JDKs; Homebrew's `openjdk` and Oracle builds follow other schedules.
        "java": EndOfLifeDefinition(product: "eclipse-temurin", scheme: .javaFeature, pathHints: ["temurin"]),
        "bun": EndOfLifeDefinition(product: "bun", scheme: .major),
        "deno": EndOfLifeDefinition(product: "deno", scheme: .automatic),
        "postgresql": EndOfLifeDefinition(product: "postgresql", scheme: .automatic),
        "mysql": EndOfLifeDefinition(product: "mysql", scheme: .majorMinor),
        "redis": EndOfLifeDefinition(product: "redis", scheme: .majorMinor),
        "mongodb": EndOfLifeDefinition(product: "mongodb", scheme: .majorMinor),
    ]

    static func withEndOfLife(_ definition: ToolDefinition) -> ToolDefinition {
        var definition = definition
        definition.endOfLife = endOfLifeProducts[definition.id]
        return definition
    }
}
