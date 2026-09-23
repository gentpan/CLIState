import CLIStateDomain
import Foundation

/// TCC-protected folders. Touching anything inside them can show a permission
/// prompt, so discovery never lists or stats paths below them (F12).
public struct ProtectedLocations: Sendable {
    public static let homeRelativeFolders = [
        "Desktop",
        "Documents",
        "Downloads",
        "Library/Mobile Documents",
        "Library/CloudStorage",
    ]

    public let roots: [String]
    private let loweredRoots: [String]

    public init(home: String) {
        let base = home.hasSuffix("/") && home != "/" ? String(home.dropLast()) : home
        roots = Self.homeRelativeFolders.map { base + "/" + $0 }
        loweredRoots = roots.map { $0.lowercased() }
    }

    /// Case-insensitive because the default APFS volume is.
    public func contains(_ path: String) -> Bool {
        let lowered = PathNormalization.lexical(path).lowercased()
        return loweredRoots.contains { lowered == $0 || lowered.hasPrefix($0 + "/") }
    }
}
