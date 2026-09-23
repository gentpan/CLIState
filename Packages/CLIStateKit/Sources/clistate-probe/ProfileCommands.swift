import CLIStateApplication
import CLIStateDomain
import Foundation

// `clistate-probe profile …` (Lane N). Read-only: export, diff and templates.
// There is deliberately no install command here; installs need the App's confirmation.

let profileUsage = """
usage: clistate-probe profile <command>

  export [file]                     scan and write a profile (stdout when no file)
  diff <file | template:<id>>       compare a profile or template with this Mac
  templates                         list built-in templates and their packages
"""

func runProfileCommand(_ arguments: [String]) async throws -> Int32 {
    guard let subcommand = arguments.first else {
        print(profileUsage)
        return 2
    }
    switch subcommand {
    case "templates":
        for template in EnvironmentRestore.templates {
            print(template.id)
            for item in template.items {
                print("  \(item.provider.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0)) \(item.qualifiedName)  [\(item.toolID?.rawValue ?? "-")]")
            }
        }
        return 0

    case "export":
        guard arguments.count <= 2 else { print(profileUsage); return 2 }
        let environment = AppEnvironment.live(inMemoryPersistence: true)
        guard let snapshot = await environment.scan.scan(depth: .fast) else {
            print("scan failed")
            return 1
        }
        let packages = await EnvironmentRestore.scannedPackages(environment.scan)
        let profile = EnvironmentRestore.exportProfile(snapshot: snapshot, packages: packages, source: .current(appVersion: "probe"))
        let data = try profile.encoded()
        if arguments.count == 2 {
            try data.write(to: URL(fileURLWithPath: arguments[1]))
            print("wrote \(profile.items.count) items to \(arguments[1])")
        } else {
            print(String(decoding: data, as: UTF8.self))
        }
        let brewfile = EnvironmentRestore.brewfile(for: profile)
        if !brewfile.isEmpty, arguments.count == 2 {
            print("\nBrewfile:\n\(brewfile)", terminator: "")
        }
        return 0

    case "diff":
        guard arguments.count == 2 else { print(profileUsage); return 2 }
        let source = arguments[1]
        let profile: EnvironmentProfile
        if source.hasPrefix("template:") {
            let id = String(source.dropFirst("template:".count))
            guard let template = EnvironmentRestore.template(id) else {
                print("unknown template \(id); try `clistate-probe profile templates`")
                return 2
            }
            profile = template.profile
        } else {
            do {
                profile = try EnvironmentProfile.decode(from: Data(contentsOf: URL(fileURLWithPath: source)))
            } catch {
                print("\(source): not a CLIState profile")
                return 1
            }
        }
        let environment = AppEnvironment.live(inMemoryPersistence: true)
        guard let snapshot = await environment.scan.scan(depth: .fast) else {
            print("scan failed")
            return 1
        }
        let diff = EnvironmentRestore.diff(profile, snapshot: snapshot)
        if profile.isNewerSchema { print("note: schema \(profile.schemaVersion) is newer than this build understands") }
        print("\(profile.items.count) items · \(diff.installed.count) installed · \(diff.versionDiffers.count) version differs · \(diff.installable.count) to install · \(diff.unavailable.count) unavailable")
        for entry in diff.entries {
            print("  \(describe(entry.status).padding(toLength: 34, withPad: " ", startingAt: 0)) \(entry.item.provider.rawValue) \(entry.item.qualifiedName)")
        }
        let stages = EnvironmentRestore.stages(for: diff.installable.map(\.item), snapshot: snapshot)
        for group in stages.ready {
            print("now      \(group.provider.rawValue): \(group.requests.map(\.qualifiedName).joined(separator: " "))")
        }
        for group in stages.deferred {
            print("later    \(group.provider.rawValue) (after \(group.enabledBy.map(\.rawValue).joined(separator: ", "))): \(group.requests.map(\.qualifiedName).joined(separator: " "))")
        }
        if diff.unavailable.contains(where: { $0.status == .unavailable(.providerMissing(.homebrew)) }) {
            print("Homebrew is not installed. Install it yourself in Terminal:\n  \(EnvironmentRestore.homebrewInstallCommand)")
        }
        return 0

    default:
        print(profileUsage)
        return 2
    }
}

private func describe(_ status: ProfileItemStatus) -> String {
    switch status {
    case let .installed(version, provider): "installed \(version ?? "") via \(provider.rawValue)"
    case let .versionDiffers(installed, expected, provider): "differs \(installed) < \(expected) via \(provider.rawValue)"
    case .pending: "to install"
    case let .pendingAfter(provider, enabledBy): "after \(enabledBy.map(\.rawValue).joined(separator: ",")) (\(provider.rawValue))"
    case let .unavailable(.providerMissing(provider)): "unavailable: no \(provider.rawValue)"
    case let .unavailable(.unsupportedProvider(raw)): "unavailable: unknown provider \(raw)"
    case .unavailable(.invalidPackageName): "unavailable: invalid name"
    }
}
