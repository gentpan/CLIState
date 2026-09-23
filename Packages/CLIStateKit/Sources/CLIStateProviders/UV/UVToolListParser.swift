import Foundation

/// Parses `uv tool list [--show-paths] [--outdated]`:
///
///     kimi-cli v1.49.0 [latest: 1.50.0] (/Users/x/.local/share/uv/tools/kimi-cli)
///     - kimi (/Users/x/.local/bin/kimi)
enum UVToolListParser {
    struct Entry: Equatable {
        var name: String
        var version: String?
        var latestVersion: String?
        var path: String?
        var executables: [Executable] = []
    }

    struct Executable: Equatable {
        var name: String
        var path: String?
    }

    static func parse(_ output: String) -> [Entry] {
        var entries: [Entry] = []
        for rawLine in OutputText.lines(output) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("- ") {
                guard !entries.isEmpty else { continue }
                let (body, path) = splitTrailingPath(String(line.dropFirst(2)))
                let name = body.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                entries[entries.count - 1].executables.append(Executable(name: name, path: path))
            } else if let entry = header(line) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// `uv 0.11.8 (0e961dd9a 2026-04-27 aarch64-apple-darwin)` → `0.11.8`.
    static func version(from output: String) -> String? {
        guard let line = OutputText.firstLine(output) else { return nil }
        let tokens = line.split(separator: " ")
        guard tokens.count >= 2, tokens[0] == "uv" else { return nil }
        return String(tokens[1])
    }

    private static func header(_ line: String) -> Entry? {
        let (body, path) = splitTrailingPath(line)
        let tokens = body.split(separator: " ").map(String.init)
        guard let name = tokens.first, tokens.count >= 2, tokens[1].hasPrefix("v"), tokens[1].count > 1 else { return nil }
        return Entry(name: name, version: String(tokens[1].dropFirst()), latestVersion: bracketValue("latest", in: body), path: path)
    }

    /// `… (path)` → body and path. Paths may contain spaces, so split at the last ` (`.
    private static func splitTrailingPath(_ text: String) -> (String, String?) {
        guard text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) else { return (text, nil) }
        let path = String(text[open.upperBound..<text.index(before: text.endIndex)])
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return (text, nil) }
        return (String(text[..<open.lowerBound]), path)
    }

    /// `[latest: 1.50.0]` → `1.50.0`.
    private static func bracketValue(_ key: String, in text: String) -> String? {
        guard let start = text.range(of: "[\(key): ") else { return nil }
        guard let end = text[start.upperBound...].firstIndex(of: "]") else { return nil }
        let value = text[start.upperBound..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
