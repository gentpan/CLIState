import CLIStateDomain
import Foundation

/// Inventory packages indexed by the keys attribution produces, plus reverse
/// dependencies computed locally from inventory data (C9).
struct PackageIndex: Sendable {
    struct Entry: Hashable, Sendable {
        var providerID: ProviderID
        var instanceID: ProviderInstanceID?
        var tool: ProviderTool
        var installationID: InstallationID
        var toolID: ToolID
        var definition: ToolDefinition?
        var scannedAt: Date
        var dependencyScope: String
    }

    private(set) var entries: [Entry] = []
    private var byKey: [String: Int] = [:]
    private var byExecutablePath: [String: Int] = [:]
    private var dependents: [String: [String: Set<String>]] = [:]

    init(inventories: [ProviderInventory], registry: ToolRegistry) {
        var seen = Set<InstallationID>()
        for inventory in inventories {
            let provider = inventory.providerID
            let rootID = inventory.layout[.npmGlobalRoot].map(NPMInstanceInfo.instanceID(root:))
            for tool in inventory.tools.sorted(by: { $0.packageName < $1.packageName }) {
                let instance = tool.instanceID ?? (provider == .npm ? (inventory.instance?.id ?? rootID) : nil)
                let installationID = InstallationID.package(provider: provider, instance: instance, name: tool.packageName)
                guard seen.insert(installationID).inserted else { continue }
                let definition = registry.definition(forPackage: tool.packageName, provider: provider)
                let scope = "\(provider.rawValue)|\(instance?.rawValue ?? "")"
                let entry = Entry(
                    providerID: provider,
                    instanceID: instance,
                    tool: tool,
                    installationID: installationID,
                    toolID: definition?.id ?? MergeEngine.packageToolID(provider: provider, package: tool.packageName),
                    definition: definition,
                    scannedAt: inventory.scannedAt,
                    dependencyScope: scope
                )
                let index = entries.count
                entries.append(entry)

                let instances: [ProviderInstanceID?] = [tool.instanceID, inventory.instance?.id, rootID, nil]
                for instanceVariant in instances.uniqued() {
                    for name in Self.nameVariants(tool.packageName, provider: provider) {
                        let key = Self.key(provider, instanceVariant, name)
                        if byKey[key] == nil { byKey[key] = index }
                    }
                }
                for path in tool.executablePaths where byExecutablePath[path] == nil {
                    byExecutablePath[path] = index
                }
                for dependency in tool.dependencies {
                    let name = provider == .homebrew ? PathUtil.lastComponent(dependency) : dependency
                    dependents[scope, default: [:]][name, default: []].insert(tool.packageName)
                }
            }
        }
    }

    func entry(for ownership: Ownership) -> Entry? {
        guard let package = ownership.packageName else { return nil }
        for name in Self.nameVariants(package, provider: ownership.provider) {
            if let index = byKey[Self.key(ownership.provider, ownership.instance, name)] { return entries[index] }
        }
        return nil
    }

    func entry(forExecutablePath path: String) -> Entry? {
        byExecutablePath[path].map { entries[$0] }
    }

    func entry(provider: ProviderID, packageName: String) -> Entry? {
        entry(for: Ownership(provider: provider, packageName: packageName, confidence: .unknown))
    }

    func dependents(of entry: Entry) -> [String] {
        let table = dependents[entry.dependencyScope] ?? [:]
        let names = Self.nameVariants(entry.tool.packageName, provider: entry.providerID)
        return names.reduce(into: Set<String>()) { $0.formUnion(table[$1] ?? []) }.sorted()
    }

    private static func nameVariants(_ name: String, provider: ProviderID) -> [String] {
        provider == .homebrew ? [name, PathUtil.lastComponent(name)].uniqued() : [name]
    }

    private static func key(_ provider: ProviderID, _ instance: ProviderInstanceID?, _ name: String) -> String {
        "\(provider.rawValue)\u{1F}\(instance?.rawValue ?? "")\u{1F}\(name)"
    }
}
