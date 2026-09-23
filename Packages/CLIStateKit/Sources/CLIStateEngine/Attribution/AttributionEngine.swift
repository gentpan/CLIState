import CLIStateDomain
import Foundation

/// Result of attributing one executable path.
public struct Attribution: Hashable, Sendable {
    public var ownership: Ownership
    /// Version implied by the path: Cellar/Caskroom directory, nvm `v<ver>`,
    /// native `versions/<ver>` (F9).
    public var pathVersion: String?
    public var installPrefix: String?
    /// Registry tool whose layout matched: a native install (rule 7) or a uv-managed Python.
    public var layoutDefinitionID: ToolID?
    public var packageKind: PackageKind?
    /// Homebrew formula whose interpreter runs this script (rule 8b), e.g. `python@3.14`
    /// for a console script `pip` wrote into `/opt/homebrew/bin`.
    public var interpreterFormula: String?
    /// Version from the package's own metadata on disk (bun's `package.json`,
    /// Cargo's `.crates2.json`), used when no inventory lists the package.
    public var manifestVersion: String?

    public init(ownership: Ownership, pathVersion: String? = nil, installPrefix: String? = nil, layoutDefinitionID: ToolID? = nil, packageKind: PackageKind? = nil, interpreterFormula: String? = nil, manifestVersion: String? = nil) {
        self.ownership = ownership
        self.pathVersion = pathVersion
        self.installPrefix = installPrefix
        self.layoutDefinitionID = layoutDefinitionID
        self.packageKind = packageKind
        self.interpreterFormula = interpreterFormula
        self.manifestVersion = manifestVersion
    }
}

/// Decides who installed an executable, with evidence (plan §6.4). Rules are
/// evaluated in order and the first match wins. Path-based only: it never runs
/// the executable. Native layouts are upgraded to Confirmed separately, once a
/// probe has reported a version (`confirmingNative`).
public struct AttributionEngine: Sendable {
    public let registry: ToolRegistry
    public let context: AttributionContext
    private let fileSystem: any FileSystem
    private let cargoMetadata: CargoInstallMetadata

    public init(fileSystem: any FileSystem, registry: ToolRegistry = .standard, context: AttributionContext) {
        self.fileSystem = fileSystem
        self.registry = registry
        self.context = context
        self.cargoMetadata = CargoInstallMetadata.read(cargoHome: context.cargoHome, fileSystem: fileSystem)
    }

    public func attribute(_ candidate: BinaryCandidate) -> Attribution {
        attribute(name: candidate.name, path: candidate.path, resolvedPath: candidate.resolvedPath)
    }

    /// Broken links are attributed by their absolute destination string (F6).
    public func attribute(_ link: BrokenSymlink) -> Attribution {
        attribute(name: PathUtil.lastComponent(link.path), path: link.path, resolvedPath: link.absoluteDestination)
    }

    public func attribute(name: String, path: String, resolvedPath: String?) -> Attribution {
        let path = PathUtil.trimmed(path)
        let effective = PathUtil.trimmed(resolvedPath ?? path)

        if let result = systemRule(path: path, effective: effective) { return result }
        if let result = homebrewRule(effective: effective) { return result }
        if let result = npmRule(effective: effective) { return result }
        if let result = pnpmRule(path: path, effective: effective) { return result }
        if let result = versionManagerRule(path: path, effective: effective) { return result }
        if let result = cargoRule(name: name, path: path, effective: effective) { return result }
        if let result = pythonToolRule(name: name, effective: effective) { return result }
        if let result = nativeLayoutRule(name: name, path: path, effective: effective) { return result }
        if let result = appBundleRule(effective: effective) { return result }
        if let result = kegInterpreterScriptRule(effective: effective) { return result }

        return Attribution(ownership: Ownership(
            provider: .standalone,
            confidence: .unknown,
            evidence: [.pathDirectory(PathUtil.directory(of: path))]
        ))
    }

    /// C4: a registry-known layout plus a path version equal to the version the
    /// executable reports is enough to confirm a native installation.
    public static func confirmingNative(_ ownership: Ownership, pathVersion: String, probedVersion: String) -> Ownership {
        guard VersionText.normalized(pathVersion) == VersionText.normalized(probedVersion),
              ownership.evidence.contains(where: { if case .knownLayout = $0 { true } else { false } })
        else { return ownership }
        var confirmed = ownership
        confirmed.confidence = .confirmed
        let evidence = AttributionEvidence.versionMatches(VersionText.normalized(probedVersion))
        if !confirmed.evidence.contains(evidence) { confirmed.evidence.append(evidence) }
        return confirmed
    }

    // MARK: Rule 1 — system

    /// Rule 1 locations: the OS itself plus Apple's developer directories.
    static func isSystemLocation(_ path: String) -> Bool {
        if isOperatingSystemLocation(path) || PathUtil.isInside(path, "/Library/Developer/CommandLineTools") { return true }
        // /Applications/Xcode*.app/Contents/Developer/…
        let parts = path.split(separator: "/", maxSplits: 4)
        return parts.count >= 4 && parts[0] == "Applications" && parts[1].hasPrefix("Xcode")
            && parts[1].hasSuffix(".app") && parts[2] == "Contents" && parts[3] == "Developer"
    }

    /// SIP-protected and cryptex-mounted locations the user can neither fix nor
    /// clean up. Problems here are informational (F3, F6); Apple's developer
    /// directories are excluded because a missing one reflects the user's setup.
    static func isOperatingSystemLocation(_ path: String) -> Bool {
        let roots = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/libexec", "/System", "/Library/Apple",
                     "/var/run/com.apple.security.cryptexd", "/private/var/run/com.apple.security.cryptexd"]
        return roots.contains { PathUtil.isInside(path, $0) }
    }

    private func systemRule(path: String, effective: String) -> Attribution? {
        let location: String
        if Self.isSystemLocation(effective) {
            location = PathUtil.directory(of: effective)
        } else if Self.isSystemLocation(path) {
            location = PathUtil.directory(of: path)
        } else {
            return nil
        }
        return Attribution(ownership: Ownership(provider: .system, confidence: .confirmed, evidence: [.systemLocation(location)]))
    }

    // MARK: Rule 2 — Homebrew Cellar / Caskroom

    /// Confirmed = the inventory lists the package *and* the resolved path lies in
    /// that package's own prefix (the symlink evidence). Rules 3 and 6 work the same way.
    private func homebrewRule(effective: String) -> Attribution? {
        for prefix in context.homebrewPrefixes {
            for (directory, kind) in [("Cellar", PackageKind.formula), ("Caskroom", .cask), ("opt", .formula)] {
                guard let parts = PathUtil.components(of: effective, below: "\(prefix)/\(directory)"), let package = parts.first else { continue }
                // `opt/<formula>` only appears unresolved, i.e. in broken link destinations.
                let version = directory == "opt" ? nil : (parts.count >= 2 ? parts[1] : nil)
                let packageRoot = "\(prefix)/\(directory)/\(package)"
                let inInventory = context.inventoryContains(provider: .homebrew, package: package)
                var evidence: [AttributionEvidence] = []
                if inInventory { evidence.append(.inventoryContains(provider: .homebrew, package: package)) }
                evidence.append(.symlinkResolvesInto(packageRoot))
                return Attribution(
                    ownership: Ownership(provider: .homebrew, packageName: package, confidence: inInventory ? .confirmed : .probable, evidence: evidence),
                    pathVersion: version,
                    installPrefix: version.map { "\(packageRoot)/\($0)" } ?? packageRoot,
                    packageKind: kind
                )
            }
        }
        return nil
    }

    // MARK: Rule 3 — npm global roots (F8)

    private func npmRule(effective: String) -> Attribution? {
        let scanned = context.npmInstances
            .filter { PathUtil.components(of: effective, below: $0.root) != nil }
            .max { $0.root.count < $1.root.count }
        let root: String
        let instanceID: ProviderInstanceID
        var packages: Set<String>? = nil
        if let scanned {
            root = scanned.root
            instanceID = scanned.id
            packages = scanned.packages
        } else if let range = effective.range(of: "/lib/node_modules/") {
            root = String(effective[..<range.lowerBound]) + "/lib/node_modules"
            guard nodePrefix(ofRoot: root) != nil else { return nil }
            instanceID = NPMInstanceInfo.instanceID(root: root)
        } else {
            return nil
        }
        guard let parts = PathUtil.components(of: effective, below: root), let first = parts.first else { return nil }
        let package: String
        if first.hasPrefix("@") {
            guard parts.count >= 2 else { return nil }
            package = "\(first)/\(parts[1])"
        } else {
            package = first
        }

        let inInventory = packages?.contains(package) == true
        var evidence: [AttributionEvidence] = []
        if inInventory { evidence.append(.inventoryContains(provider: .npm, package: package)) }
        evidence.append(.symlinkResolvesInto("\(root)/\(package)"))
        // Record which Node installation this npm root belongs to (F8).
        if let node = nodePrefix(ofRoot: root) { evidence.append(.knownLayout(node)) }
        return Attribution(
            ownership: Ownership(provider: .npm, instance: instanceID, packageName: package, confidence: inInventory ? .confirmed : .probable, evidence: evidence),
            installPrefix: "\(root)/\(package)",
            packageKind: .globalPackage
        )
    }

    /// The Node prefix owning `<prefix>/lib/node_modules`, when it is a known one:
    /// a Homebrew prefix, a version-manager install, or a directory with `bin/node`.
    private func nodePrefix(ofRoot root: String) -> String? {
        guard root.hasSuffix("/lib/node_modules") else { return nil }
        let prefix = String(root.dropLast("/lib/node_modules".count))
        if context.homebrewPrefixes.contains(prefix) { return prefix }
        if context.versionManagerRoots.contains(where: { PathUtil.components(of: prefix, below: $0.root) != nil }) { return prefix }
        if fileSystem.exists(atPath: "\(prefix)/bin/node") { return prefix }
        return nil
    }

    // MARK: Rule 3b — pnpm global shims

    /// pnpm's global bin holds shell shims, not links, so nothing in the path points at
    /// the package. The exact file the pnpm inventory lists for a package is the evidence.
    private func pnpmRule(path: String, effective: String) -> Attribution? {
        guard let (location, listed) = [path, effective].lazy.compactMap({ candidate in context.pnpmExecutables[candidate].map { (candidate, $0) } }).first
        else { return nil }
        return Attribution(
            ownership: Ownership(provider: .pnpm, packageName: listed.package, confidence: .confirmed,
                                 evidence: [.inventoryContains(provider: .pnpm, package: listed.package), .knownLayout(PathUtil.directory(of: location))]),
            installPrefix: listed.installPrefix,
            packageKind: .globalPackage
        )
    }

    // MARK: Rule 4 — version managers

    private func versionManagerRule(path: String, effective: String) -> Attribution? {
        for candidate in [effective, path].uniqued() {
            for (provider, root) in context.versionManagerRoots {
                guard let parts = PathUtil.components(of: candidate, below: root) else { continue }
                let version: String?
                let prefixCount: Int
                switch provider {
                case .nvm:
                    // versions/node/v26.2.0/…
                    let matches = parts.count >= 3 && parts[0] == "versions"
                    version = matches ? parts[2] : nil
                    prefixCount = 3
                case .fnm:
                    // node-versions/v22.1.0/installation/…
                    let matches = parts.count >= 2 && parts[0] == "node-versions"
                    version = matches ? parts[1] : nil
                    prefixCount = 2
                case .pyenv, .rbenv:
                    let matches = parts.count >= 2 && parts[0] == "versions"
                    version = matches ? parts[1] : nil
                    prefixCount = 2
                case .mise, .asdf:
                    // installs/<tool>/<version>/…
                    let matches = parts.count >= 3 && parts[0] == "installs"
                    version = matches ? parts[2] : nil
                    prefixCount = 3
                case .volta:
                    // tools/image/<tool>/<version>/…
                    let matches = parts.count >= 4 && parts[0] == "tools" && parts[1] == "image"
                    version = matches ? parts[3] : nil
                    prefixCount = 4
                default:
                    version = nil
                    prefixCount = 0
                }
                let installPrefix = version.map { _ in ([root] + parts.prefix(prefixCount)).joined(separator: "/") }
                return Attribution(
                    ownership: Ownership(provider: provider, confidence: .probable, evidence: [.knownLayout(root)]),
                    pathVersion: version.map(VersionText.normalized),
                    installPrefix: installPrefix
                )
            }
        }
        return nil
    }

    // MARK: Rule 5 — Cargo / rustup

    static let rustupProxyNames: Set<String> = [
        "cargo", "cargo-clippy", "cargo-fmt", "cargo-miri", "clippy-driver", "rls", "rust-analyzer",
        "rust-gdb", "rust-gdbgui", "rust-lldb", "rustc", "rustdoc", "rustfmt", "rustup",
    ]

    private func cargoRule(name: String, path: String, effective: String) -> Attribution? {
        let rustupToolchains = "\(context.rustupHome)/toolchains"
        if let parts = PathUtil.components(of: effective, below: rustupToolchains), let toolchain = parts.first {
            return Attribution(
                ownership: Ownership(provider: .rustup, confidence: .probable, evidence: [.knownLayout(rustupToolchains)]),
                installPrefix: "\(rustupToolchains)/\(toolchain)"
            )
        }
        let bin = context.cargoBin
        guard let location = [path, effective].first(where: { PathUtil.directory(of: $0) == bin }) else { return nil }
        if isRustupProxy(name: name, path: location, effective: effective, bin: bin) {
            return Attribution(ownership: Ownership(
                provider: .rustup, confidence: .probable,
                evidence: [.knownLayout(bin), .symlinkResolvesInto("\(bin)/rustup")]
            ))
        }

        let binary = PathUtil.lastComponent(location)
        let recorded = cargoMetadata.installsByBinary[binary]
        let metadataEvidence = AttributionEvidence.knownLayout("\(context.cargoHome)/\(CargoInstallMetadata.fileName)")
        if let listed = context.cargoExecutables[location] {
            // `cargo install --list` names the crate that owns this binary.
            var evidence: [AttributionEvidence] = [.inventoryContains(provider: .cargo, package: listed.package), .knownLayout(bin)]
            if recorded?.crate == listed.package { evidence.append(metadataEvidence) }
            return Attribution(
                ownership: Ownership(provider: .cargo, packageName: listed.package, confidence: .confirmed, evidence: evidence),
                installPrefix: listed.installPrefix ?? bin,
                packageKind: .tool
            )
        }
        if let recorded {
            return Attribution(
                ownership: Ownership(provider: .cargo, packageName: recorded.crate, confidence: .probable, evidence: [.knownLayout(bin), metadataEvidence]),
                installPrefix: bin,
                packageKind: .tool,
                manifestVersion: recorded.version
            )
        }
        return Attribution(ownership: Ownership(provider: .cargo, confidence: .probable, evidence: [.knownLayout(bin)]))
    }

    private func isRustupProxy(name: String, path: String, effective: String, bin: String) -> Bool {
        let target = PathUtil.lastComponent(effective)
        if target == "rustup" || target == "rustup-init" { return true }
        // rustup installs proxies as hard links of itself, so compare with the rustup binary.
        guard Self.rustupProxyNames.contains(name),
              let rustup = fileSystem.attributes(atPath: "\(bin)/rustup"),
              let proxy = fileSystem.attributes(atPath: effective)
        else { return false }
        return rustup.size > 0 && rustup.size == proxy.size && rustup.modifiedAt == proxy.modifiedAt
    }

    // MARK: Rule 6 — uv / pipx

    private func pythonToolRule(name: String, effective: String) -> Attribution? {
        let layouts: [(ProviderID, [String])] = [(.uv, context.uvToolDirectories), (.pipx, context.pipxVenvDirectories)]
        for (provider, directories) in layouts {
            for directory in directories {
                guard let parts = PathUtil.components(of: effective, below: directory), let package = parts.first else { continue }
                let inInventory = context.inventoryContains(provider: provider, package: package)
                var evidence: [AttributionEvidence] = []
                if inInventory { evidence.append(.inventoryContains(provider: provider, package: package)) }
                evidence.append(.symlinkResolvesInto("\(directory)/\(package)"))
                return Attribution(
                    ownership: Ownership(provider: provider, packageName: package, confidence: inInventory ? .confirmed : .probable, evidence: evidence),
                    installPrefix: "\(directory)/\(package)",
                    packageKind: .tool
                )
            }
        }
        return uvPythonRule(name: name, effective: effective) ?? bunGlobalRule(effective: effective)
    }

    /// `uv python install` puts interpreters in `<python dir>/cpython-3.12.13-macos-aarch64-none/`
    /// and links `~/.local/bin/python3.12` there. The directory name carries the version.
    /// Only the interpreter itself joins the registry's Python; `pip3` or `idle3` from the
    /// same directory stay separate tools.
    private func uvPythonRule(name: String, effective: String) -> Attribution? {
        for directory in context.uvPythonDirectories {
            guard let parts = PathUtil.components(of: effective, below: directory), parts.count >= 2,
                  let layout = UVPythonDirectory(name: parts[0])
            else { continue }
            let isInterpreter = name.hasPrefix("python") && name.dropFirst("python".count).allSatisfy { $0 == "." || ($0.isASCII && $0.isNumber) }
            return Attribution(
                ownership: Ownership(provider: .uv, confidence: .probable, evidence: [.knownLayout(directory)]),
                pathVersion: layout.version,
                installPrefix: "\(directory)/\(parts[0])",
                layoutDefinitionID: layout.isCPython && isInterpreter ? "python" : nil
            )
        }
        return nil
    }

    /// Same shape as rule 6 for `bun add -g`: links in `~/.bun/bin` resolve into
    /// `~/.bun/install/global/node_modules/<package>`. No bun inventory in 1.0, so Probable;
    /// the version comes from the package's own `package.json`.
    private func bunGlobalRule(effective: String) -> Attribution? {
        let root = context.bunGlobalModules
        guard let parts = PathUtil.components(of: effective, below: root), let first = parts.first else { return nil }
        let package: String
        if first.hasPrefix("@") {
            guard parts.count >= 2 else { return nil }
            package = "\(first)/\(parts[1])"
        } else {
            package = first
        }
        return Attribution(
            ownership: Ownership(provider: .bun, packageName: package, confidence: .probable, evidence: [.symlinkResolvesInto("\(root)/\(package)")]),
            installPrefix: "\(root)/\(package)",
            packageKind: .globalPackage,
            manifestVersion: PackageManifest.version(packageDirectory: "\(root)/\(package)", expectedName: package, fileSystem: fileSystem)
        )
    }

    // MARK: Rule 7 — registry native layouts

    private func nativeLayoutRule(name: String, path: String, effective: String) -> Attribution? {
        for definition in registry.definitions where !definition.nativeLayouts.isEmpty && definition.executables.contains(name) {
            for layout in definition.nativeLayouts {
                if let marker = layout.marker, !fileSystem.exists(atPath: context.expand(marker)) { continue }
                switch layout.kind {
                case let .versionedRoot(template):
                    let root = context.expand(template)
                    guard let parts = PathUtil.components(of: effective, below: root), let version = parts.first else { continue }
                    return Attribution(
                        ownership: Ownership(provider: layout.provider, confidence: .probable, evidence: [.knownLayout(root)]),
                        pathVersion: VersionText.normalized(version),
                        installPrefix: "\(root)/\(version)",
                        layoutDefinitionID: definition.id
                    )
                case let .directory(template):
                    let directory = context.expand(template)
                    guard PathUtil.directory(of: effective) == directory || PathUtil.directory(of: path) == directory else { continue }
                    var evidence: [AttributionEvidence] = [.knownLayout(directory)]
                    if let marker = layout.marker { evidence.append(.knownLayout(context.expand(marker))) }
                    return Attribution(
                        ownership: Ownership(provider: layout.provider, confidence: .probable, evidence: evidence),
                        installPrefix: PathUtil.directory(of: directory),
                        layoutDefinitionID: definition.id
                    )
                case let .file(template):
                    let file = context.expand(template)
                    guard effective == file || path == file else { continue }
                    var evidence: [AttributionEvidence] = [.knownLayout(file)]
                    if let marker = layout.marker { evidence.append(.knownLayout(context.expand(marker))) }
                    return Attribution(
                        ownership: Ownership(provider: layout.provider, confidence: .probable, evidence: evidence),
                        layoutDefinitionID: definition.id
                    )
                }
            }
        }
        return bundledHelperRule(name: name, path: path)
    }

    /// Another executable in a directory a registry tool's installer owns. Helpers
    /// that are registry tools themselves (`rg`) stay their own tool, with the host
    /// as `packageName`, so a later Homebrew ripgrep still shows who wins in PATH;
    /// anything else (`fd`, backups) joins the host's installation.
    private func bundledHelperRule(name: String, path: String) -> Attribution? {
        for definition in registry.definitions {
            for layout in definition.nativeLayouts where layout.bundlesHelpers {
                guard case let .directory(template) = layout.kind, let marker = layout.marker else { continue }
                let directory = context.expand(template)
                guard PathUtil.directory(of: path) == directory, fileSystem.exists(atPath: context.expand(marker)) else { continue }
                let helperIsRegistryTool = registry.definition(forExecutable: name) != nil
                return Attribution(
                    ownership: Ownership(provider: layout.provider, packageName: helperIsRegistryTool ? definition.id.rawValue : nil, confidence: .probable,
                                         evidence: [.knownLayout(directory), .knownLayout(context.expand(marker))]),
                    installPrefix: PathUtil.directory(of: directory),
                    layoutDefinitionID: helperIsRegistryTool ? nil : definition.id
                )
            }
        }
        return nil
    }

    // MARK: Rule 8 — app bundles

    private func appBundleRule(effective: String) -> Attribution? {
        guard let range = effective.range(of: ".app/Contents/") else { return nil }
        let bundle = String(effective[..<range.lowerBound]) + ".app"
        return Attribution(
            ownership: Ownership(provider: .appBundle, packageName: PathUtil.lastComponent(bundle), confidence: .probable, evidence: [.knownLayout(bundle)]),
            installPrefix: bundle
        )
    }

    // MARK: Rule 8b — scripts run by a Homebrew keg's interpreter

    /// A plain script whose `#!` names an interpreter inside a Homebrew keg, such as the
    /// console scripts `pip` writes into `/opt/homebrew/bin` (`#!/opt/homebrew/opt/python@3.14/bin/python3.14`).
    /// Only the literal keg path counts: `#!/usr/bin/env python3` depends on PATH, and a
    /// venv's `bin/python` merely links to the keg without being Homebrew's environment.
    /// The interpreter must still resolve into a Cellar formula, so scripts left behind
    /// by a removed Python stay unrecognized. Probable, and never a Homebrew package.
    private func kegInterpreterScriptRule(effective: String) -> Attribution? {
        guard let shebang = Shebang.read(atPath: effective, fileSystem: fileSystem) else { return nil }
        let interpreter = shebang.interpreter
        guard !interpreter.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        for prefix in context.homebrewPrefixes {
            let inKeg = ["opt", "Cellar"].contains { directory in
                (PathUtil.components(of: interpreter, below: "\(prefix)/\(directory)")?.count ?? 0) >= 2
            }
            guard inKeg,
                  let resolved = fileSystem.resolvingSymlinks(atPath: interpreter),
                  let cellar = PathUtil.components(of: resolved, below: "\(prefix)/Cellar"), cellar.count >= 3,
                  fileSystem.isExecutableFile(atPath: resolved)
            else { continue }
            return Attribution(
                ownership: Ownership(provider: .homebrew, confidence: .probable, evidence: [.knownLayout(interpreter)]),
                interpreterFormula: cellar[0]
            )
        }
        return nil
    }
}
