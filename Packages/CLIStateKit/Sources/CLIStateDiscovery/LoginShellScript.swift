import CLIStateDomain
import Foundation

/// The single fixed script run inside the user's login shell, and the parser for
/// its output. This is the only place in the app where shell code exists.
///
/// Output layout (interactive rc files may print anything before or after):
///
///     \n__CLISTATE_BEGIN__\n
///     KEY=value\0KEY=value\0…            ← `/usr/bin/env -0`
///     \n__CLISTATE_SHADOWS__\n
///     __CLISTATE_NAME__:node\n
///     node: function\n                   ← `whence -wa` / `type -at`
///     \n__CLISTATE_END__\n
public enum LoginShellScript {
    static let beginMarker = "__CLISTATE_BEGIN__"
    static let shadowsMarker = "__CLISTATE_SHADOWS__"
    static let endMarker = "__CLISTATE_END__"
    static let namePrefix = "__CLISTATE_NAME__:"
    static let maximumNameLength = 128

    public struct Output: Hashable, Sendable {
        public var variables: [String: String]
        public var shadows: [String: [ShellShadow]]
    }

    /// Keeps only names matching `^[A-Za-z0-9._+-]+$`, in order, without duplicates.
    /// Anything else never reaches the script.
    public static func sanitizedCandidates(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { name in
            guard isSafeName(name), !seen.contains(name) else { return false }
            seen.insert(name)
            return true
        }
    }

    public static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maximumNameLength else { return false }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "+"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }

    public static func make(kind: ShellDescriptor.Kind, shadowCandidates: [String]) -> String {
        let names = sanitizedCandidates(shadowCandidates)
        let printf: String
        let lookup: ((String) -> String)?
        switch kind {
        case .zsh:
            printf = "builtin printf"
            lookup = { "builtin whence -wa -- \($0) 2>/dev/null" }
        case .bash:
            printf = "builtin printf"
            lookup = { "builtin type -at -- \($0) 2>/dev/null" }
        case .fish:
            // `type` is a function in fish 3 and a builtin in fish 4.
            printf = "builtin printf"
            lookup = { "type -a -t -- \($0) 2>/dev/null" }
        case .sh, .other:
            printf = "printf"
            lookup = nil
        }

        var statements = [
            "\(printf) '\\n\(beginMarker)\\n'",
            "/usr/bin/env -0",
            "\(printf) '\\n\(shadowsMarker)\\n'",
        ]
        if let lookup {
            for name in names {
                // Safe: `name` contains only [A-Za-z0-9._+-].
                statements.append("\(printf) '%s\\n' '\(namePrefix)\(name)'")
                statements.append(lookup(name))
            }
        }
        statements.append("\(printf) '\\n\(endMarker)\\n'")
        return statements.joined(separator: "; ")
    }

    /// Returns `nil` when any marker is missing.
    public static func parse(_ stdout: Data) -> Output? {
        let bytes = [UInt8](stdout)
        let begin = Array("\(beginMarker)\n".utf8)
        let separator = Array("\n\(shadowsMarker)\n".utf8)
        let end = Array("\n\(endMarker)\n".utf8)

        guard let beginRange = firstRange(of: begin, in: bytes, from: 0) else { return nil }
        let environmentStart = beginRange.upperBound

        // `env -0` terminates every entry with NUL, and values cannot contain NUL,
        // so the real separator is either right after BEGIN or right after a NUL.
        var searchFrom = environmentStart
        var separatorRange: Range<Int>?
        while let candidate = firstRange(of: separator, in: bytes, from: searchFrom) {
            if candidate.lowerBound == environmentStart || bytes[candidate.lowerBound - 1] == 0 {
                separatorRange = candidate
                break
            }
            searchFrom = candidate.lowerBound + 1
        }
        guard let separatorRange else { return nil }
        guard let endRange = firstRange(of: end, in: bytes, from: separatorRange.upperBound - 1) else { return nil }

        let variables = parseEnvironment(bytes[environmentStart..<separatorRange.lowerBound])
        let shadowText = separatorRange.upperBound <= endRange.lowerBound
            ? String(decoding: bytes[separatorRange.upperBound..<endRange.lowerBound], as: UTF8.self)
            : ""
        return Output(variables: variables, shadows: parseShadows(shadowText))
    }

    static func parseEnvironment(_ bytes: ArraySlice<UInt8>) -> [String: String] {
        var variables: [String: String] = [:]
        for entry in bytes.split(separator: 0, omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: UInt8(ascii: "=")), equals > entry.startIndex else { continue }
            let key = String(decoding: entry[entry.startIndex..<equals], as: UTF8.self)
            let value = String(decoding: entry[(equals + 1)...], as: UTF8.self)
            variables[key] = value
        }
        return variables
    }

    static func parseShadows(_ text: String) -> [String: [ShellShadow]] {
        var shadows: [String: [ShellShadow]] = [:]
        var current: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(namePrefix) {
                let name = String(line.dropFirst(namePrefix.count))
                current = isSafeName(name) ? name : nil
                continue
            }
            guard let name = current else { continue }
            // zsh prints `name: kind`; bash and fish print just `kind`.
            let word = line.range(of: ": ", options: .backwards).map { String(line[$0.upperBound...]) } ?? line
            guard let kind = shadowKind(word) else { continue }
            let shadow = ShellShadow(name: name, kind: kind)
            if !(shadows[name]?.contains(shadow) ?? false) {
                shadows[name, default: []].append(shadow)
            }
        }
        return shadows
    }

    /// `command`, `file` and `none` mean a plain PATH lookup: no shadow.
    static func shadowKind(_ word: String) -> ShellShadow.Kind? {
        switch word {
        case "alias": return .alias
        case "function": return .function
        case "builtin": return .builtin
        case "reserved", "keyword": return .reserved
        case "hashed": return .hashed
        default: return nil
        }
    }

    private static func firstRange(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Range<Int>? {
        guard !needle.isEmpty, start >= 0, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        guard start <= last else { return nil }
        let first = needle[0]
        var index = start
        while index <= last {
            if haystack[index] == first, haystack[index..<(index + needle.count)].elementsEqual(needle) {
                return index..<(index + needle.count)
            }
            index += 1
        }
        return nil
    }
}
