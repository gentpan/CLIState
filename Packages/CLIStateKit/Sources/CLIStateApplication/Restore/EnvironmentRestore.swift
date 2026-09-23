import CLIStateDomain
import CLIStateEngine
import CLIStateProviders
import Foundation

/// Environment restore (Lane N) for the App and the probe: export, Brewfile,
/// templates, AI whitelist, diff and install staging. Pure functions over a
/// snapshot, so sample data and live scans go through the same logic. Installs
/// themselves are `OperationRequest.install` plans run by `OperationCoordinator`.
public enum EnvironmentRestore {
    static let catalog = RestoreCatalog(registry: .standard)

    /// Package names are checked with the same validator every plan builder uses (§178).
    public static func isValidPackageName(_ name: String) -> Bool {
        PackageNameValidator.isValid(name)
    }

    // MARK: Layer 1: export

    public static func exportProfile(snapshot: EnvironmentSnapshot, packages: [ProviderTool] = [], source: ProfileSource? = nil, name: String? = nil, note: String? = nil, createdAt: Date = Date()) -> EnvironmentProfile {
        ProfileExporter(isValidName: isValidPackageName)
            .profile(from: snapshot, packages: packages, source: source, name: name, note: note, createdAt: createdAt)
    }

    /// Every package the providers reported in the last scan, for cask, tap and pin details.
    public static func scannedPackages(_ scan: ScanCoordinator) async -> [ProviderTool] {
        var packages: [ProviderTool] = []
        for provider in RestoreCatalog.installOrder {
            packages += await scan.inventory(for: provider)?.tools ?? []
        }
        return packages
    }

    public static func brewfile(for profile: EnvironmentProfile) -> String {
        BrewfileWriter.brewfile(for: profile, isValidName: isValidPackageName)
    }

    // MARK: Layers 2 and 3: templates and AI whitelist

    public static var templates: [EnvironmentTemplate] { catalog.templates }

    public static func template(_ id: String) -> EnvironmentTemplate? { catalog.template(id) }

    /// Registry tools an AI suggestion may pick from; anything else is dropped.
    public static var candidates: [RestoreCandidate] { catalog.candidates }

    /// A checklist profile from chosen registry tools, each through its preferred package.
    public static func profile(forTools toolIDs: [ToolID], name: String? = nil) -> EnvironmentProfile {
        let byID = Dictionary(candidates.map { ($0.toolID, $0.item) }, uniquingKeysWith: { first, _ in first })
        return EnvironmentProfile(createdAt: Date(timeIntervalSince1970: 0), name: name, items: toolIDs.compactMap { byID[$0] })
    }

    // MARK: Import

    public static func diff(_ profile: EnvironmentProfile, snapshot: EnvironmentSnapshot) -> ProfileDiff {
        ProfileDiffer(registry: .standard, isValidName: isValidPackageName).diff(profile, snapshot: snapshot)
    }

    /// What can run now and what waits for an earlier stage, given the latest snapshot.
    /// Call again after each stage's rescan: installing Node.js makes npm available.
    public static func stages(for items: [ProfileItem], snapshot: EnvironmentSnapshot) -> RestoreStagePlan {
        RestorePlanner.stages(for: items) { provider in
            snapshot.providers.first { $0.providerID == provider }?.availability.isAvailable ?? false
        }
    }

    /// The official Homebrew installer command, shown for the user to copy and run
    /// themselves in Terminal. CLIState never runs it.
    public static let homebrewInstallCommand = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
}

extension ProfileSource {
    /// Architecture and macOS version only; no host or user names.
    public static func current(appVersion: String?) -> ProfileSource {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
        return ProfileSource(architecture: architecture, macOSVersion: macOS, appVersion: appVersion)
    }
}
