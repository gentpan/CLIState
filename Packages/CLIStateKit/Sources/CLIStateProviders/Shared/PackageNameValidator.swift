import CLIStateDomain
import Foundation

/// Guards every plan builder against argument injection (§178). Names come from
/// provider inventories, but plans can be rebuilt from stored data, so each one
/// is checked again before it becomes a command argument.
public enum PackageNameValidator {
    /// Longer than any real npm (214) or Homebrew name.
    public static let maximumLength = 256

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+._/-")

    /// Accepts npm scopes (`@anthropic-ai/claude-code`) and tap names
    /// (`user/tap/name`). Rejects anything a package manager could read as an
    /// option (`-x`) or a local path (`./pkg`, `/abs`, `a/../b`).
    public static func validate(_ name: String) throws {
        guard isValid(name) else { throw ProviderError.invalidPackageName(name) }
    }

    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maximumLength else { return false }
        guard name.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return false }
        guard let first = name.first, first != "-", first != ".", first != "/" else { return false }
        guard !name.hasSuffix("/") else { return false }
        let segments = name.split(separator: "/", omittingEmptySubsequences: false)
        return segments.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix("-") }
    }

    static func validateAll<S: Sequence>(_ names: S) throws where S.Element == String {
        for name in names { try validate(name) }
    }
}
