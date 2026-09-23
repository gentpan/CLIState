import Foundation

/// Parses `cargo install --list`:
///
///     deepseek-tui v0.8.20:
///         deepseek-tui
///     local-tool v0.1.0 (/Users/x/src/local-tool):
///         local-tool
///     git-tool v1.2.0 (https://github.com/x/git-tool?branch=main#1a2b3c4d):
///         git-tool
///
/// Cargo prints a source in parentheses only when it is not crates.io.
enum CargoInstallListParser {
    enum Source: Equatable {
        case path(String)
        case git(String)
        /// Alternative or local registry (`registry `name``), `dir …` sources.
        case other(String)
    }

    struct Entry: Equatable {
        var name: String
        var version: String
        var source: Source?
        var binaries: [String] = []
    }

    static func parse(_ output: String) -> [Entry] {
        var entries: [Entry] = []
        for line in OutputText.lines(output) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if line.first?.isWhitespace == true {
                guard !entries.isEmpty else { continue }
                entries[entries.count - 1].binaries.append(trimmed)
            } else if let entry = header(trimmed) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// `cargo 1.95.0 (f2d3ce0bd 2026-03-21) (Homebrew)` → `1.95.0`.
    static func version(from output: String) -> String? {
        guard let line = OutputText.firstLine(output) else { return nil }
        let tokens = line.split(separator: " ")
        guard tokens.count >= 2, tokens[0] == "cargo" else { return nil }
        return String(tokens[1])
    }

    private static func header(_ line: String) -> Entry? {
        guard line.hasSuffix(":") else { return nil }
        let body = line.dropLast()
        let parts = body.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[1].hasPrefix("v"), parts[1].count > 1 else { return nil }
        let entry = Entry(name: String(parts[0]), version: String(parts[1].dropFirst()))
        guard parts.count == 3 else { return entry }

        // Paths may contain spaces and parentheses, so take everything between
        // the first `(` and the final `)`.
        let rest = parts[2].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("("), rest.hasSuffix(")"), rest.count > 2 else {
            return Entry(name: entry.name, version: entry.version, source: .other(rest))
        }
        return Entry(name: entry.name, version: entry.version, source: source(String(rest.dropFirst().dropLast())))
    }

    private static func source(_ text: String) -> Source {
        if text.hasPrefix("registry ") || text.hasPrefix("dir ") { return .other(text) }
        if text.hasPrefix("/") { return .path(text) }
        if text.contains("://") { return .git(text) }
        return .other(text)
    }
}
