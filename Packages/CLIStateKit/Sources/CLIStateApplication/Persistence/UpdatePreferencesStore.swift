import CLIStateDomain
import Foundation

/// Keeps `UpdatePreferences` as JSON in user defaults. A stored value that doesn't
/// decode (damaged, or written by a newer version) loads as defaults and is left
/// untouched: only `save`, which runs when the user changes a setting, replaces it.
public struct UpdatePreferencesStore: @unchecked Sendable {
    public enum LoadState: Equatable, Sendable {
        case missing, loaded, unreadable
    }

    public static let defaultsKey = "UpdatePreferences"

    // `UserDefaults` is thread-safe.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> (preferences: UpdatePreferences, state: LoadState) {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return (UpdatePreferences(), .missing) }
        guard let stored = try? JSONDecoder().decode(UpdatePreferences.self, from: data) else { return (UpdatePreferences(), .unreadable) }
        return (stored, .loaded)
    }

    public func save(_ preferences: UpdatePreferences) throws {
        defaults.set(try JSONEncoder().encode(preferences), forKey: Self.defaultsKey)
    }
}
