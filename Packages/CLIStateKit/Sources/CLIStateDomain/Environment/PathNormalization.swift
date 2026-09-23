import Foundation

/// Lexical path normalization that never touches the disk. `NSString.standardizingPath`
/// resolves `..` and `/private` prefixes against the real filesystem, so the same
/// input could normalize differently on another Mac (it made CI fail).
public enum PathNormalization {
    /// Collapses `//`, `.` and `..`, keeps the result absolute when the input was,
    /// and removes a trailing slash (except for `/`).
    public static func lexical(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var stack: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append(component)
                }
            default:
                stack.append(component)
            }
        }
        let joined = stack.joined(separator: "/")
        if isAbsolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }
}
