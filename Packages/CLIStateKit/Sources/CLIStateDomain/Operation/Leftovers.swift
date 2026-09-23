import Foundation

// MARK: - Leftovers

/// What a leftover file or directory holds. Decides the default selection:
/// regenerable kinds are preselected, user data never is.
public enum LeftoverKind: String, Codable, Sendable, CaseIterable {
    /// Regenerated on demand, e.g. `~/Library/Caches/deno`.
    case cache
    case logs
    /// Runtime state such as `~/.local/state/<name>`.
    case state
    /// Settings, sometimes credentials, e.g. `~/.config/gh`.
    case config
    /// History, sessions, credentials, e.g. `~/.claude`.
    case data

    /// Settings, credentials or history the user may want to keep.
    public var containsUserData: Bool { self == .config || self == .data }
}

/// A file or directory a tool left in the home directory, found by a
/// `LeftoverScanning` implementation after its safety rules passed.
public struct LeftoverItem: Identifiable, Hashable, Codable, Sendable {
    public enum Origin: String, Codable, Sendable {
        /// Declared for this tool in the registry.
        case registry
        /// A standard location whose last component exactly equals the tool or package name.
        case exactName
    }

    public var id: String { path }
    /// Absolute path, never inside an installation's own prefix.
    public var path: String
    public var kind: LeftoverKind
    public var origin: Origin
    /// Sum of regular-file sizes found by a bounded walk.
    public var sizeBytes: Int64
    /// `true` when the walk stopped early, so `sizeBytes` is a minimum.
    public var sizeIsLowerBound: Bool

    public init(path: String, kind: LeftoverKind, origin: Origin, sizeBytes: Int64, sizeIsLowerBound: Bool = false) {
        self.path = path
        self.kind = kind
        self.origin = origin
        self.sizeBytes = sizeBytes
        self.sizeIsLowerBound = sizeIsLowerBound
    }

    public var containsUserData: Bool { kind.containsUserData }
}

/// Finds leftovers for a tool. Read-only; the Application layer re-runs it at
/// prepare and execute time and only moves paths it returned to the Trash.
public protocol LeftoverScanning: Sendable {
    /// Works for tools that are no longer in the snapshot too (registry knowledge only).
    func leftovers(for tool: ToolID, in snapshot: EnvironmentSnapshot) -> [LeftoverItem]
}
