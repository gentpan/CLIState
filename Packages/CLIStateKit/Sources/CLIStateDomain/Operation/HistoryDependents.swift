import Foundation

/// An installation an operation changed besides its targets, e.g. a Homebrew
/// dependent upgraded together with the formula the user asked for.
public struct HistoryDependent: Hashable, Sendable {
    public var installationID: InstallationID
    /// Package name taken from the installation ID (`homebrew:composer` → `composer`).
    public var name: String
    public var version: String

    public init(installationID: InstallationID, name: String, version: String) {
        self.installationID = installationID
        self.name = name
        self.version = version
    }
}

extension CommandHistoryEntry {
    /// `verifiedVersions` keys are installation IDs. Target IDs are the requested
    /// installations; every other key is a dependent the rescan observed.
    public var targetVersions: [InstallationID: String] {
        let targetIDs = Set(targets.compactMap(\.installationID?.rawValue))
        var versions: [InstallationID: String] = [:]
        for (key, version) in verifiedVersions where targetIDs.contains(key) {
            versions[InstallationID(key)] = version
        }
        return versions
    }

    public var dependents: [HistoryDependent] {
        let targetIDs = Set(targets.compactMap(\.installationID?.rawValue))
        return verifiedVersions
            .filter { !targetIDs.contains($0.key) }
            .map { key, version in
                let name = key.split(separator: ":").last.map(String.init) ?? key
                return HistoryDependent(installationID: InstallationID(key), name: name, version: version)
            }
            .sorted { ($0.name, $0.installationID.rawValue) < ($1.name, $1.installationID.rawValue) }
    }
}
