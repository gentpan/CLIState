import Foundation

public enum PATHEntryStatus: String, Codable, Sendable {
    case ok
    case missing
    case notDirectory
    /// Same normalized directory already appeared earlier; not rescanned (§108).
    case duplicate
    /// Relative entry such as `.` or `bin` — resolved against the working directory.
    case relative
    case empty
    /// TCC-protected location (Desktop, Documents, Downloads, iCloud). Skipped so
    /// scanning never triggers a permission prompt (F12).
    case protectedLocation
    case unreadable
}

public enum PATHSource: String, Codable, Sendable {
    case homebrew, system, userLocal, cargo, go, bun, npm, versionManager, application, unknown
}

public struct PATHEntry: Identifiable, Hashable, Codable, Sendable {
    /// 1-based priority; also the identity within one snapshot.
    public var id: Int { priority }
    public var priority: Int
    /// Exactly as it appeared in PATH (may contain `~` or a trailing slash).
    public var rawValue: String
    /// `~` expanded, trailing `/` removed.
    public var normalizedPath: String
    public var status: PATHEntryStatus
    public var source: PATHSource
    public var isWritable: Bool
    public var executableCount: Int
    /// Priority of the earlier entry this one duplicates.
    public var duplicateOf: Int?

    public init(
        priority: Int,
        rawValue: String,
        normalizedPath: String,
        status: PATHEntryStatus,
        source: PATHSource,
        isWritable: Bool = false,
        executableCount: Int = 0,
        duplicateOf: Int? = nil
    ) {
        self.priority = priority
        self.rawValue = rawValue
        self.normalizedPath = normalizedPath
        self.status = status
        self.source = source
        self.isWritable = isWritable
        self.executableCount = executableCount
        self.duplicateOf = duplicateOf
    }
}

public enum CPUArchitecture: String, Codable, Sendable {
    case arm64
    case x86_64
    case universal
    /// `#!` interpreter script.
    case script
    case unknown
}

/// One executable file found in a PATH directory (§109). Version is not probed here.
public struct BinaryCandidate: Hashable, Codable, Sendable {
    public var name: String
    /// Path inside the PATH directory, e.g. `/opt/homebrew/bin/php`.
    public var path: String
    public var pathPriority: Int
    public var isSymlink: Bool
    /// `realpath` of `path`, e.g. `/opt/homebrew/Cellar/php/8.5.7/bin/php`.
    public var resolvedPath: String?
    public var size: Int64?
    public var modifiedAt: Date?

    public init(name: String, path: String, pathPriority: Int, isSymlink: Bool, resolvedPath: String?, size: Int64? = nil, modifiedAt: Date? = nil) {
        self.name = name
        self.path = path
        self.pathPriority = pathPriority
        self.isSymlink = isSymlink
        self.resolvedPath = resolvedPath
        self.size = size
        self.modifiedAt = modifiedAt
    }

    public var effectivePath: String { resolvedPath ?? path }
}

/// All candidates sharing one executable name, ordered by PATH priority (§110).
public struct BinaryGroup: Hashable, Codable, Sendable {
    public var executableName: String
    public var candidates: [BinaryCandidate]

    public init(executableName: String, candidates: [BinaryCandidate]) {
        self.executableName = executableName
        self.candidates = candidates.sorted { $0.pathPriority < $1.pathPriority }
    }

    /// What the terminal runs for a plain PATH lookup.
    public var active: BinaryCandidate? { candidates.first }
}

public struct BrokenSymlink: Hashable, Codable, Sendable {
    public var path: String
    /// Raw link destination (possibly relative).
    public var destination: String
    public var pathPriority: Int

    public init(path: String, destination: String, pathPriority: Int) {
        self.path = path
        self.destination = destination
        self.pathPriority = pathPriority
    }

    /// Destination made absolute against the link's directory, not resolved.
    public var absoluteDestination: String {
        if destination.hasPrefix("/") { return PathNormalization.lexical(destination) }
        let directory = (path as NSString).deletingLastPathComponent
        return PathNormalization.lexical((directory as NSString).appendingPathComponent(destination))
    }
}

public struct BinaryInventory: Hashable, Codable, Sendable {
    public var groups: [String: BinaryGroup]
    public var brokenSymlinks: [BrokenSymlink]

    public init(groups: [String: BinaryGroup] = [:], brokenSymlinks: [BrokenSymlink] = []) {
        self.groups = groups
        self.brokenSymlinks = brokenSymlinks
    }

    /// Equivalent of `which -a <name>`.
    public func candidates(named name: String) -> [BinaryCandidate] {
        groups[name]?.candidates ?? []
    }

    public var executableCount: Int { groups.values.reduce(0) { $0 + $1.candidates.count } }
}

/// Output of environment discovery (Milestone 1).
public struct DiscoveryResult: Sendable {
    public var session: ShellSession
    public var pathEntries: [PATHEntry]
    public var binaries: BinaryInventory

    public init(session: ShellSession, pathEntries: [PATHEntry], binaries: BinaryInventory) {
        self.session = session
        self.pathEntries = pathEntries
        self.binaries = binaries
    }
}
