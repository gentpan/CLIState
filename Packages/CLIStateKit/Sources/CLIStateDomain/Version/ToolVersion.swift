import Foundation

/// A version exactly as observed. Never forced into semver (§118):
/// `8.4.12`, `go1.25.1`, `1.6.3_1`, `0.0.0-next-15329`, `HEAD`.
public struct ToolVersion: Hashable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var description: String { rawValue }

    /// Best-effort semantic parse; `nil` when the raw value is not version-like.
    public var semantic: SemanticVersion? { SemanticVersion(parsing: rawValue) }
}

/// Numeric version with optional prerelease and Homebrew-style revision.
public struct SemanticVersion: Hashable, Sendable, Comparable {
    public var components: [Int]
    public var prerelease: [String]
    /// Homebrew `_N` revision suffix.
    public var revision: Int

    public init(components: [Int], prerelease: [String] = [], revision: Int = 0) {
        self.components = components
        self.prerelease = prerelease
        self.revision = revision
    }

    /// Accepts an optional `v` / `go` prefix, 1–4 numeric components, `-prerelease`,
    /// `+build` (ignored) and `_revision`.
    public init?(parsing raw: String) {
        var text = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        for prefix in ["go", "v", "V"] where text.hasPrefix(prefix) {
            text = text.dropFirst(prefix.count)
            break
        }
        if let plus = text.firstIndex(of: "+") { text = text[..<plus] }

        var revision = 0
        if let underscore = text.lastIndex(of: "_"), let value = Int(text[text.index(after: underscore)...]) {
            revision = value
            text = text[..<underscore]
        }

        var prerelease: [String] = []
        if let dash = text.firstIndex(of: "-") {
            prerelease = text[text.index(after: dash)...].split(separator: ".").map(String.init)
            text = text[..<dash]
        }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        self.init(components: numbers, prerelease: prerelease, revision: revision)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        // A release sorts after its prereleases.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, false): return false
        case (false, true): return true
        case (false, false):
            if lhs.prerelease != rhs.prerelease {
                return lhs.prerelease.lexicographicallyPrecedes(rhs.prerelease) { a, b in
                    switch (Int(a), Int(b)) {
                    case let (x?, y?): return x < y
                    case (_?, nil): return true
                    case (nil, _?): return false
                    default: return a < b
                    }
                }
            }
        case (true, true): break
        }
        return lhs.revision < rhs.revision
    }
}

public enum UpdateKind: String, Codable, Sendable {
    case patch, minor, major, unknown

    /// `unknown` whenever either side has a prerelease/channel tag or does not parse (§142, F10).
    public static func between(_ current: ToolVersion, _ latest: ToolVersion) -> UpdateKind {
        guard let from = current.semantic, let to = latest.semantic,
              from.prerelease.isEmpty, to.prerelease.isEmpty, from < to
        else { return .unknown }
        let a = from.components + [0, 0, 0]
        let b = to.components + [0, 0, 0]
        if a[0] != b[0] { return .major }
        if a[1] != b[1] { return .minor }
        return .patch
    }
}

public enum ObservationSource: Hashable, Codable, Sendable {
    case provider(ProviderID)
    case executable(String)
    case path
    case registry
    case filesystem
    case cache
    case inferred
    case updateSource(String)
}

public enum ObservationConfidence: String, Codable, Sendable {
    case confirmed, probable, unknown
}

/// A value with provenance, so the UI can always answer "where did this come from?" (§214–§216).
public struct ObservedValue<Value: Hashable & Codable & Sendable>: Hashable, Codable, Sendable {
    public var value: Value
    public var source: ObservationSource
    public var confidence: ObservationConfidence
    public var observedAt: Date

    public init(_ value: Value, source: ObservationSource, confidence: ObservationConfidence, observedAt: Date) {
        self.value = value
        self.source = source
        self.confidence = confidence
        self.observedAt = observedAt
    }
}
