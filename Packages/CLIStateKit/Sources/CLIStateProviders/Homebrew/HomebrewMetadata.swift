import CLIStateDomain
import Foundation

/// When Homebrew last downloaded its package index (`brew update`). `brew outdated`
/// compares against this local copy, so "latest" is only as new as this date —
/// including when someone ran `brew update` outside CLIState.
enum HomebrewMetadata {
    static func lastUpdated(prefix: String, cacheDirectory: String?, fileSystem: any FileSystem) -> Date? {
        let cache = cacheDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? fileSystem.homeDirectory + "/Library/Caches/Homebrew"
        var candidates = [
            // API mode (default since Homebrew 4): the downloaded index.
            cache + "/api/formula.jws.json",
            cache + "/api/cask.jws.json",
            // Every `brew update` fetches the Homebrew/brew repository. Apple silicon keeps
            // it at the prefix, Intel at `<prefix>/Homebrew`.
            prefix + "/.git/FETCH_HEAD",
            prefix + "/Homebrew/.git/FETCH_HEAD",
            // Tapped core repositories (HOMEBREW_NO_INSTALL_FROM_API).
            prefix + "/Library/Taps/homebrew/homebrew-core/.git/FETCH_HEAD",
            prefix + "/Homebrew/Library/Taps/homebrew/homebrew-core/.git/FETCH_HEAD",
        ]
        let internalDirectory = cache + "/api/internal"
        if let names = try? fileSystem.contentsOfDirectory(atPath: internalDirectory) {
            candidates += names.filter { $0.hasSuffix(".jws.json") }.map { internalDirectory + "/" + $0 }
        }
        return candidates.compactMap { fileSystem.attributes(atPath: $0)?.modifiedAt }.max()
    }
}
