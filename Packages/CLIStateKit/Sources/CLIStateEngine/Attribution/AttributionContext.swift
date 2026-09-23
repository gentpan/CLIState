import CLIStateDomain
import Foundation

/// A scanned npm instance: its global root and the packages `npm list -g` reported.
public struct NPMInstanceInfo: Hashable, Sendable {
    public var id: ProviderInstanceID
    public var root: String
    public var packages: Set<String>

    public init(id: ProviderInstanceID, root: String, packages: Set<String>) {
        self.id = id
        self.root = PathUtil.trimmed(root)
        self.packages = packages
    }

    public static func instanceID(root: String) -> ProviderInstanceID {
        ProviderInstanceID("npm@\(PathUtil.trimmed(root))")
    }
}

/// An executable path a provider's inventory lists for one of its packages.
public struct ListedExecutable: Hashable, Sendable {
    public var package: String
    public var installPrefix: String?

    public init(package: String, installPrefix: String? = nil) {
        self.package = package
        self.installPrefix = installPrefix
    }
}

/// Everything attribution needs besides the filesystem: provider roots taken
/// from inventories and locator variables from the user's shell (C11).
public struct AttributionContext: Sendable {
    public var homeDirectory: String
    public var homebrewPrefixes: [String]
    public var npmInstances: [NPMInstanceInfo]
    public var uvToolDirectories: [String]
    public var pipxVenvDirectories: [String]
    /// uv-managed interpreters: `$UV_PYTHON_INSTALL_DIR`, else `$XDG_DATA_HOME/uv/python`.
    public var uvPythonDirectories: [String]
    /// `bun add -g` package root: `$BUN_INSTALL/install/global/node_modules`.
    public var bunGlobalModules: String
    public var cargoHome: String
    /// `cargo install` target: the Cargo inventory's `cargoBin`, else `$CARGO_HOME/bin`.
    public var cargoBin: String
    /// `<cargoBin>/<bin>` → crate, from `cargo install --list`.
    public var cargoExecutables: [String: ListedExecutable]
    /// Shim scripts in pnpm's global bin → package, from the pnpm inventory.
    public var pnpmExecutables: [String: ListedExecutable]
    public var rustupHome: String
    /// Version-manager roots in rule order.
    public var versionManagerRoots: [(provider: ProviderID, root: String)]
    /// `provider` → package names found in that provider's inventories (short and full names).
    public var inventoryPackages: [ProviderID: Set<String>]

    public init(homeDirectory: String, variables: [String: String], inventories: [ProviderInventory]) {
        let home = PathUtil.trimmed(homeDirectory)
        self.homeDirectory = home
        func variable(_ key: String) -> String? {
            guard let value = variables[key], !value.isEmpty else { return nil }
            return PathUtil.trimmed(PathUtil.expandingTilde(value, home: home))
        }
        let xdgData = variable("XDG_DATA_HOME") ?? "\(home)/.local/share"

        var brewPrefixes: [String] = []
        var npmInstances: [NPMInstanceInfo] = []
        var uvDirectories: [String] = []
        var pipxVenvs: [String] = []
        var cargoLayout: (home: String?, bin: String?) = (nil, nil)
        var cargoExecutables: [String: ListedExecutable] = [:]
        var pnpmExecutables: [String: ListedExecutable] = [:]
        var packages: [ProviderID: Set<String>] = [:]
        for inventory in inventories {
            for tool in inventory.tools {
                packages[inventory.providerID, default: []].insert(tool.packageName)
                if inventory.providerID == .homebrew {
                    packages[inventory.providerID, default: []].insert(PathUtil.lastComponent(tool.packageName))
                }
            }
            switch inventory.providerID {
            case .homebrew:
                if let prefix = inventory.layout[.homebrewPrefix] { brewPrefixes.append(PathUtil.trimmed(prefix)) }
            case .npm:
                let root = inventory.layout[.npmGlobalRoot]
                    ?? inventory.instance.flatMap { Self.root(fromInstanceID: $0.id) }
                    ?? inventory.tools.lazy.compactMap { $0.instanceID.flatMap(Self.root(fromInstanceID:)) }.first
                guard let root else { continue }
                let id = inventory.instance?.id ?? NPMInstanceInfo.instanceID(root: root)
                npmInstances.append(NPMInstanceInfo(id: id, root: root, packages: Set(inventory.tools.map(\.packageName))))
            case .uv:
                if let directory = inventory.layout[.uvToolDir] { uvDirectories.append(PathUtil.trimmed(directory)) }
            case .pipx:
                if let directory = inventory.layout[.pipxVenvs] { pipxVenvs.append(PathUtil.trimmed(directory)) }
            case .cargo:
                cargoLayout = (inventory.layout[.cargoHome].map(PathUtil.trimmed), inventory.layout[.cargoBin].map(PathUtil.trimmed))
                for tool in inventory.tools {
                    for path in tool.executablePaths where cargoExecutables[path] == nil {
                        cargoExecutables[path] = ListedExecutable(package: tool.packageName, installPrefix: tool.installPrefix)
                    }
                }
            case .pnpm:
                for tool in inventory.tools {
                    for path in tool.executablePaths where pnpmExecutables[path] == nil {
                        pnpmExecutables[path] = ListedExecutable(package: tool.packageName, installPrefix: tool.installPrefix)
                    }
                }
            default:
                break
            }
        }
        if let prefix = variable("HOMEBREW_PREFIX") { brewPrefixes.append(prefix) }
        brewPrefixes += ["/opt/homebrew", "/usr/local"]
        self.homebrewPrefixes = brewPrefixes.uniqued()
        self.npmInstances = npmInstances
        self.uvToolDirectories = (uvDirectories + [variable("UV_TOOL_DIR"), "\(xdgData)/uv/tools"].compactMap { $0 }).uniqued()
        self.uvPythonDirectories = [variable("UV_PYTHON_INSTALL_DIR"), "\(xdgData)/uv/python"].compactMap { $0 }.uniqued()
        self.pipxVenvDirectories = (pipxVenvs + [variable("PIPX_HOME").map { "\($0)/venvs" }, "\(home)/.local/pipx/venvs", "\(xdgData)/pipx/venvs"].compactMap { $0 }).uniqued()
        self.bunGlobalModules = "\(variable("BUN_INSTALL") ?? "\(home)/.bun")/install/global/node_modules"
        self.cargoHome = cargoLayout.home ?? variable("CARGO_HOME") ?? "\(home)/.cargo"
        self.cargoBin = cargoLayout.bin ?? "\(cargoHome)/bin"
        self.cargoExecutables = cargoExecutables
        self.pnpmExecutables = pnpmExecutables
        self.rustupHome = variable("RUSTUP_HOME") ?? "\(home)/.rustup"
        self.inventoryPackages = packages

        var managers: [(ProviderID, String)] = []
        managers.append((.nvm, variable("NVM_DIR") ?? "\(home)/.nvm"))
        for root in [variable("FNM_DIR"), "\(xdgData)/fnm", "\(home)/Library/Application Support/fnm", "\(home)/.fnm"].compactMap({ $0 }).uniqued() {
            managers.append((.fnm, root))
        }
        managers.append((.volta, variable("VOLTA_HOME") ?? "\(home)/.volta"))
        managers.append((.mise, variable("MISE_DATA_DIR") ?? "\(xdgData)/mise"))
        managers.append((.asdf, variable("ASDF_DATA_DIR") ?? "\(home)/.asdf"))
        managers.append((.pyenv, variable("PYENV_ROOT") ?? "\(home)/.pyenv"))
        managers.append((.rbenv, variable("RBENV_ROOT") ?? "\(home)/.rbenv"))
        self.versionManagerRoots = managers.map { (provider: $0.0, root: $0.1) }
    }

    public func inventoryContains(provider: ProviderID, package: String) -> Bool {
        inventoryPackages[provider]?.contains(package) == true
    }

    public func expand(_ template: String) -> String {
        PathUtil.expandingTilde(template, home: homeDirectory)
    }

    static func root(fromInstanceID id: ProviderInstanceID) -> String? {
        guard let at = id.rawValue.firstIndex(of: "@") else { return nil }
        let root = id.rawValue[id.rawValue.index(after: at)...]
        return root.hasPrefix("/") ? String(root) : nil
    }
}
