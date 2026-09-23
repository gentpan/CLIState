import CLIStateApplication
import CLIStateDomain
import Foundation

/// Restore work that differs between real scans and sample data. Diffs and
/// staging are pure (`EnvironmentRestore`) and computed from `AppModel.snapshot`.
@MainActor
protocol RestoreActions: AnyObject {
    /// What's installed on purpose right now; `nil` before the first scan.
    func exportProfile(name: String?, note: String?) async -> EnvironmentProfile?
    /// One plan per provider group, in the order given, behind one confirmation.
    func planInstall(_ groups: [RestoreProviderGroup], snapshot: EnvironmentSnapshot?) async throws -> PreparedOperation
}

extension LiveActions: RestoreActions {
    func exportProfile(name: String?, note: String?) async -> EnvironmentProfile? {
        guard let snapshot = await environment.scan.snapshot else { return nil }
        let packages = await EnvironmentRestore.scannedPackages(environment.scan)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return EnvironmentRestore.exportProfile(snapshot: snapshot, packages: packages, source: .current(appVersion: version), name: name, note: note)
    }

    func planInstall(_ groups: [RestoreProviderGroup], snapshot: EnvironmentSnapshot?) async throws -> PreparedOperation {
        var plans: [PreparedPlan] = []
        for group in groups {
            let prepared = try await environment.operations.prepare(.install(group.provider, RestoreText.installRequests(group, snapshot: snapshot)))
            plans.append(PreparedPlan(plan: prepared.plan, checks: prepared.checks))
        }
        return PreparedOperation(plans: plans)
    }
}
