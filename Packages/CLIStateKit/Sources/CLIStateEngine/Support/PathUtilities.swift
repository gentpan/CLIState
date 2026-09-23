import CLIStateDomain
import Foundation

/// String-level path helpers. Deliberately avoids `NSString.standardizingPath`
/// for arbitrary paths: it rewrites `/private/var/...` based on the real disk,
/// which would make results depend on the host rather than the scanned data.
enum PathUtil {
    /// Removes trailing slashes (keeps `/`).
    static func trimmed(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    static func expandingTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    /// `true` when `path` is `root` or lies below it.
    static func isInside(_ path: String, _ root: String) -> Bool {
        let root = trimmed(root)
        if root == "/" { return path.hasPrefix("/") }
        return path == root || path.hasPrefix(root + "/")
    }

    /// Path components below `root`, or `nil` when `path` is not inside it.
    static func components(of path: String, below root: String) -> [String]? {
        let root = trimmed(root)
        guard path.hasPrefix(root + "/") else { return nil }
        return path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
    }

    static func directory(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func join(_ base: String, _ components: String...) -> String {
        components.reduce(trimmed(base)) { partial, next in
            partial == "/" ? "/" + next : partial + "/" + next
        }
    }
}

extension Array where Element: Hashable {
    /// Keeps the first occurrence of each element, preserving order.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

enum VersionText {
    /// Drops a leading `v` so `v26.2.0` (nvm dir, `node --version`) equals `26.2.0`.
    static func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 1, trimmed.hasPrefix("v"), trimmed.dropFirst().first?.isNumber == true {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    /// Highest version by semantic order; falls back to the last raw value.
    static func highest(_ versions: [String]) -> String? {
        guard !versions.isEmpty else { return nil }
        let parsed = versions.compactMap { raw in SemanticVersionBox(raw) }
        if parsed.count == versions.count {
            return parsed.max { $0.version < $1.version }?.raw
        }
        return versions.last
    }

    /// `8.5.7` → `8.5`; `17.10` → `17.10`.
    static func majorMinor(_ raw: String) -> String? {
        let numbers = numericPrefix(raw)
        guard numbers.count >= 2 else { return nil }
        return "\(numbers[0]).\(numbers[1])"
    }

    static func major(_ raw: String) -> String? {
        numericPrefix(raw).first.map(String.init)
    }

    private static func numericPrefix(_ raw: String) -> [Int] {
        var numbers: [Int] = []
        for part in normalized(raw).split(separator: ".") {
            let digits = part.prefix { $0.isASCII && $0.isNumber }
            guard let value = Int(digits) else { break }
            numbers.append(value)
            if digits.count != part.count { break }
        }
        return numbers
    }
}

struct SemanticVersionBox {
    var raw: String
    var version: SemanticVersion

    init?(_ raw: String) {
        guard let version = SemanticVersion(parsing: raw) else { return nil }
        self.raw = raw
        self.version = version
    }
}
