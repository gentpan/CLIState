import Foundation

/// Stable string identifiers. Never UUIDs: the same tool must keep the same
/// identity across scans (§114), and history rows must survive upgrades (C12).
public protocol StringIdentifier: RawRepresentable, Hashable, Comparable, Codable, Sendable,
    CustomStringConvertible, ExpressibleByStringLiteral, CodingKeyRepresentable where RawValue == String
{
    init(_ rawValue: String)
}

extension StringIdentifier {
    public init(rawValue: String) { self.init(rawValue) }
    public init(stringLiteral value: String) { self.init(value) }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        self.init(try String(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }

    /// Dictionaries keyed by identifiers encode as JSON objects, not arrays.
    public var codingKey: CodingKey { IdentifierCodingKey(stringValue: rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(codingKey.stringValue)
    }
}

struct IdentifierCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Canonical tool identity without category: `php`, `claude-code`,
/// `homebrew.aom`, `unknown.<sha256>`.
public struct ToolID: StringIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct ProviderID: StringIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }

    // Package managers with inventories.
    public static let homebrew: ProviderID = "homebrew"
    public static let npm: ProviderID = "npm"
    public static let uv: ProviderID = "uv"
    public static let pnpm: ProviderID = "pnpm"
    public static let pipx: ProviderID = "pipx"
    public static let cargo: ProviderID = "cargo"
    public static let bun: ProviderID = "bun"
    public static let go: ProviderID = "go"

    // Version managers (read-only attribution in 1.0).
    public static let rustup: ProviderID = "rustup"
    public static let nvm: ProviderID = "nvm"
    public static let fnm: ProviderID = "fnm"
    public static let volta: ProviderID = "volta"
    public static let mise: ProviderID = "mise"
    public static let asdf: ProviderID = "asdf"
    public static let pyenv: ProviderID = "pyenv"
    public static let rbenv: ProviderID = "rbenv"

    // Not package managers.
    public static let native: ProviderID = "native"
    public static let appBundle: ProviderID = "app-bundle"
    public static let system: ProviderID = "system"
    public static let standalone: ProviderID = "standalone"

    public static let versionManagers: Set<ProviderID> = [.rustup, .nvm, .fnm, .volta, .mise, .asdf, .pyenv, .rbenv]
}

/// A concrete instance of a provider, e.g. the npm that belongs to one Node
/// installation: `npm@/opt/homebrew/lib/node_modules` (§157).
public struct ProviderInstanceID: StringIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// One installation of a tool. Contains no version so it survives upgrades:
/// `homebrew:php`, `homebrew:php@8.2`, `npm@<root>:@anthropic-ai/claude-code`,
/// `path:/Users/x/.local/bin/node`.
public struct InstallationID: StringIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static func package(provider: ProviderID, instance: ProviderInstanceID? = nil, name: String) -> InstallationID {
        let owner = instance.map { $0.rawValue } ?? provider.rawValue
        return InstallationID("\(owner):\(name)")
    }

    public static func path(_ executablePath: String) -> InstallationID {
        InstallationID("path:\(executablePath)")
    }
}

public struct HostID: StringIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let local: HostID = "local"
}
