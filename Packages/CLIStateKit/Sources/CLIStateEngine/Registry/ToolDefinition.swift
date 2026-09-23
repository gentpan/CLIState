import CLIStateDomain
import Foundation

/// How to ask an executable for its version (§6.6).
public struct VersionProbe: Hashable, Sendable {
    public var arguments: [String]
    /// Regular expression whose first capture group is the version. `nil` uses
    /// the generic dotted-version pattern. Applied to stdout followed by stderr
    /// because some tools (`java -version`, `nginx -v`) print to stderr.
    public var pattern: String?

    public init(_ arguments: [String], pattern: String? = nil) {
        self.arguments = arguments
        self.pattern = pattern
    }
}

/// An install layout a registry tool's own installer creates (C4, rule 7).
public struct NativeLayout: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `<root>/<version>` or `<root>/<version>/…` — the version is in the path (F9),
        /// e.g. `~/.local/share/claude/versions/2.1.234`.
        case versionedRoot(String)
        /// Executables placed directly in an installer-owned directory, e.g. `~/.bun/bin`.
        case directory(String)
        /// One exact executable path, e.g. `~/.local/bin/uv`.
        case file(String)
    }

    public var kind: Kind
    /// Usually `.native`; Homebrew's own `brew` script uses `.homebrew`.
    public var provider: ProviderID
    /// A file the installer writes. The layout only matches when it exists, so
    /// shared directories like `~/.local/bin` never count as evidence on their own (§37).
    public var marker: String?
    /// For `.directory` layouts the installer owns exclusively: other executables
    /// in it are helpers the tool downloads for itself (Kimi Code's `rg` and `fd`).
    /// Requires a marker, so shared directories like `~/.bun/bin` never qualify.
    public var bundlesHelpers: Bool

    public init(_ kind: Kind, provider: ProviderID = .native, marker: String? = nil, bundlesHelpers: Bool = false) {
        self.kind = kind
        self.provider = provider
        self.marker = marker
        self.bundlesHelpers = bundlesHelpers && marker != nil
    }

    /// Whether the layout's path carries the installed version, which is what
    /// allows the two-evidence confirmation (C4).
    public var hasVersionInPath: Bool {
        if case .versionedRoot = kind { return true }
        return false
    }
}

/// Read-only latest-version channel for tools without a package inventory (C4).
public enum UpdateSourceDefinition: Hashable, Sendable {
    /// `npm view <package> dist-tags --json`, reading `channel`.
    case npmDistTags(package: String, channel: String)
}

/// Static knowledge about a well-known CLI (§129, §130). Holds no installed or
/// latest versions: those only come from providers, probes and update sources.
public struct ToolDefinition: Hashable, Sendable, Identifiable {
    /// Category-free identity (C12): `php`, `claude-code`.
    public var id: ToolID
    public var displayName: String
    /// English summary; the App layer localizes.
    public var summary: String
    public var category: ToolCategory
    /// Command names; the first is the primary command.
    public var executables: [String]
    /// Package names per provider. Homebrew names also match versioned formulae
    /// by base name (`php@8.2` → `php`) and tap-qualified names by last component.
    public var packages: [ProviderID: [String]]
    public var versionProbe: VersionProbe?
    public var homepage: URL?
    public var documentationURL: URL?
    /// Templates: `~` home, `{brew}` Homebrew prefix, `{mm}` major.minor, `{major}` major version.
    public var configPaths: [String]
    public var nativeLayouts: [NativeLayout]
    /// Arguments for the tool's own updater, e.g. `["update"]` for `claude update`.
    public var selfUpdateArguments: [String]?
    public var updateSource: UpdateSourceDefinition?
    /// Command the primary executable needs at runtime (`npm` → `node`).
    public var requiredRuntime: String?
    /// Directory names used by version managers (`mise/installs/<name>`, `asdf/installs/<name>`).
    public var versionManagerNames: [String]
    /// Must check `/usr/libexec/java_home` before probing (F5).
    public var requiresJavaHome: Bool
    /// Files the tool writes into the home directory outside its install
    /// prefix. Only locations known to belong to this tool; `LeftoverScanner`
    /// still applies its safety rules and existence checks.
    public var leftoverPaths: [LeftoverLocation]
    /// endoflife.date product for runtimes and databases (set from `StandardDefinitions.endOfLifeProducts`).
    public var endOfLife: EndOfLifeDefinition? = nil

    public init(
        id: ToolID,
        displayName: String,
        summary: String,
        category: ToolCategory,
        executables: [String],
        packages: [ProviderID: [String]] = [:],
        versionProbe: VersionProbe? = VersionProbe(["--version"]),
        homepage: URL? = nil,
        documentationURL: URL? = nil,
        configPaths: [String] = [],
        nativeLayouts: [NativeLayout] = [],
        selfUpdateArguments: [String]? = nil,
        updateSource: UpdateSourceDefinition? = nil,
        requiredRuntime: String? = nil,
        versionManagerNames: [String] = [],
        requiresJavaHome: Bool = false,
        leftoverPaths: [LeftoverLocation] = []
    ) {
        precondition(!executables.isEmpty, "A tool definition needs at least one executable")
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.category = category
        self.executables = executables
        self.packages = packages
        self.versionProbe = versionProbe
        self.homepage = homepage
        self.documentationURL = documentationURL
        self.configPaths = configPaths
        self.nativeLayouts = nativeLayouts
        self.selfUpdateArguments = selfUpdateArguments
        self.updateSource = updateSource
        self.requiredRuntime = requiredRuntime
        self.versionManagerNames = versionManagerNames
        self.requiresJavaHome = requiresJavaHome
        self.leftoverPaths = leftoverPaths
    }

    public var primaryExecutable: String { executables[0] }

    public var identity: ToolIdentity {
        ToolIdentity(
            name: id.rawValue,
            displayName: displayName,
            summary: summary,
            category: category,
            homepage: homepage,
            documentationURL: documentationURL,
            registryID: id.rawValue
        )
    }

    /// Native self-update command for an installation's executable, e.g. `claude update`.
    public func selfUpdateCommand(executablePath: String) -> Command? {
        guard let selfUpdateArguments else { return nil }
        return Command(executable: executablePath, arguments: selfUpdateArguments)
    }
}
