import CLIStateDomain
import Foundation

/// Parsers for Homebrew's human-readable output: dry runs, `uses`, `--version`.
/// Formats verified against Homebrew 6.0.22 (`upgrade.rb`, `cleanup.rb`).
enum HomebrewOutputParser {
    /// `Homebrew 6.0.22` → `6.0.22`.
    static func version(from output: String) -> String? {
        for line in OutputText.lines(output) {
            let tokens = line.split(separator: " ")
            if tokens.count >= 2, tokens[0] == "Homebrew" { return String(tokens[1]) }
        }
        return nil
    }

    static func firstPath(from output: String) -> String? {
        OutputText.firstLine(output).flatMap { $0.hasPrefix("/") ? $0 : nil }
    }

    // MARK: brew upgrade --dry-run

    struct UpgradeDryRun: Equatable {
        /// Collateral changes: installed dependencies, upgraded dependencies and dependents.
        var items: [PreflightItem] = []
        /// The packages the user asked for.
        var requested: [PreflightItem] = []
    }

    private enum UpgradeSection {
        case install(namesOnly: Bool)
        case dependencies
        case requested
        case dependents
    }

    static func upgradeDryRun(_ output: String) -> UpgradeDryRun {
        var result = UpgradeDryRun()
        var section: UpgradeSection?
        for rawLine in OutputText.lines(output) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("==>") {
                section = upgradeSection(header: String(line.dropFirst(3)))
                continue
            }
            guard let section, !line.isEmpty else { continue }
            switch section {
            case let .install(namesOnly) where namesOnly:
                for name in line.split(separator: " ") {
                    result.items.append(PreflightItem(name: String(name), change: .install))
                }
            case .install:
                if let item = upgradeLine(line, change: .install) { result.items.append(item) }
            case .dependencies:
                if let item = upgradeLine(line, change: .upgrade) { result.items.append(item) }
            case .dependents:
                if let item = upgradeLine(line, change: .upgradeDependent) { result.items.append(item) }
            case .requested:
                if let item = upgradeLine(line, change: .upgrade) { result.requested.append(item) }
            }
        }
        return result
    }

    private static func upgradeSection(header: String) -> UpgradeSection? {
        let text = header.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("would install") {
            // Cask dependencies print as one space-separated line: "for <cask>:".
            return .install(namesOnly: text.contains(" for "))
        }
        guard text.hasPrefix("would upgrade") else { return nil }
        if text.contains("dependent") { return .dependents }
        if text.contains("dependenc") { return .dependencies }
        return .requested
    }

    /// `name from -> to (size)`, `name from -> to` or `name version`.
    static func upgradeLine(_ line: String, change: PreflightItem.Change) -> PreflightItem? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            .filter { !($0.hasPrefix("(") && $0.hasSuffix(")")) }
        guard let name = tokens.first, !name.hasSuffix(":") else { return nil }
        if let arrow = tokens.firstIndex(of: "->") {
            let from = arrow > 1 ? tokens[arrow - 1] : nil
            let to = arrow + 1 < tokens.count ? tokens[arrow + 1] : nil
            return PreflightItem(name: name, change: change, fromVersion: from, toVersion: to)
        }
        return PreflightItem(name: name, change: change, toVersion: tokens.count > 1 ? tokens[1] : nil)
    }

    // MARK: brew cleanup --dry-run

    struct CleanupDryRun: Equatable {
        var paths: [String] = []
        /// Old kegs as `remove` items with the version being removed.
        var items: [PreflightItem] = []
        /// Homebrew's own total when printed, else the sum of per-path sizes.
        var reclaimableBytes: Int64?

        var isEmpty: Bool { paths.isEmpty && (reclaimableBytes ?? 0) == 0 }
    }

    static func cleanupDryRun(_ output: String, layout: ProviderLayout) -> CleanupDryRun {
        var result = CleanupDryRun()
        var summed: Int64 = 0
        var total: Int64?
        for rawLine in OutputText.lines(output) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Would remove: ") {
                let (path, size) = splitTrailingSize(String(line.dropFirst("Would remove: ".count)))
                result.paths.append(path)
                summed += size ?? 0
            } else if line.hasPrefix("Would remove ("), let colon = line.range(of: "): ") {
                result.paths.append(String(line[colon.upperBound...]))
            } else if line.hasPrefix("Would prune "), let from = line.range(of: " from: ") {
                result.paths.append(String(line[from.upperBound...]))
            } else if line.contains("would free approximately"),
                      let range = line.range(of: "approximately ") {
                let rest = line[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                total = byteCount(rest)
            }
        }
        result.paths = result.paths.uniquedPreservingOrder()
        result.items = result.paths.compactMap { kegItem(path: $0, layout: layout) }
        result.reclaimableBytes = total ?? (summed > 0 ? summed : nil)
        return result
    }

    /// `<path> (7,627 files, 37.6MB)` → path and bytes.
    private static func splitTrailingSize(_ text: String) -> (String, Int64?) {
        guard text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) else { return (text, nil) }
        let inner = text[open.upperBound..<text.index(before: text.endIndex)]
        let sizeToken = inner.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard let bytes = byteCount(sizeToken) else { return (text, nil) }
        return (String(text[..<open.lowerBound]), bytes)
    }

    /// Homebrew's `disk_usage_readable`: decimal units, e.g. `303.8MB`, `64B`.
    static func byteCount(_ token: String) -> Int64? {
        let units: [(String, Double)] = [("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (suffix, multiplier) in units where token.hasSuffix(suffix) {
            guard let value = Double(token.dropLast(suffix.count)), value >= 0 else { return nil }
            return Int64((value * multiplier).rounded())
        }
        return nil
    }

    private static func kegItem(path: String, layout: ProviderLayout) -> PreflightItem? {
        for root in [layout[.homebrewCellar], layout[.homebrewCaskroom]].compactMap({ $0 }) {
            guard path.hasPrefix(root + "/") else { continue }
            let parts = path.dropFirst(root.count + 1).split(separator: "/")
            guard parts.count == 2 else { continue }
            return PreflightItem(name: String(parts[0]), change: .remove, fromVersion: String(parts[1]))
        }
        return nil
    }

    // MARK: brew autoremove --dry-run

    /// `==> Would autoremove 2 unneeded formulae:` followed by one name per line.
    static func autoremoveDryRun(_ output: String) -> [String] {
        var names: [String] = []
        var inSection = false
        for rawLine in OutputText.lines(output) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("==>") {
                inSection = line.lowercased().contains("would autoremove")
                continue
            }
            guard inSection else { continue }
            if line.isEmpty { inSection = false; continue }
            names.append(contentsOf: line.split(separator: " ").map(String.init))
        }
        return names.uniquedPreservingOrder()
    }

    // MARK: brew uses --installed

    static func names(fromList output: String) -> [String] {
        OutputText.lines(output)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") && !$0.contains(" ") }
            .uniquedPreservingOrder()
    }
}
