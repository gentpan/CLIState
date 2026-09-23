import Foundation

public enum FileKind: String, Codable, Sendable {
    case file
    case directory
    case symlink
    case other
}

public struct FileAttributes: Hashable, Sendable {
    public var kind: FileKind
    public var size: Int64
    public var modifiedAt: Date?
    public var isExecutable: Bool
    /// Owning user ID (`st_uid`); `nil` when the file system can't tell.
    public var ownerID: UInt32?
    /// Last access (`st_atime`). Volumes may update it lazily or not at all.
    public var accessedAt: Date?
    /// Last inode change (`st_ctime`): content, permissions, links or extended attributes.
    public var statusChangedAt: Date?
    /// File serial number (`st_ino`), so hard links can be counted once.
    public var inode: UInt64?
    /// Number of hard links (`st_nlink`).
    public var linkCount: Int?

    public init(
        kind: FileKind,
        size: Int64 = 0,
        modifiedAt: Date? = nil,
        isExecutable: Bool = false,
        ownerID: UInt32? = nil,
        accessedAt: Date? = nil,
        statusChangedAt: Date? = nil,
        inode: UInt64? = nil,
        linkCount: Int? = nil
    ) {
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.isExecutable = isExecutable
        self.ownerID = ownerID
        self.accessedAt = accessedAt
        self.statusChangedAt = statusChangedAt
        self.inode = inode
        self.linkCount = linkCount
    }
}

/// Read-only filesystem port. Discovery and Engine use it so they can be tested
/// against `InMemoryFileSystem` without touching the real disk (§94).
public protocol FileSystem: Sendable {
    var homeDirectory: String { get }

    /// User ID of the running process, compared with `FileAttributes.ownerID`.
    /// `nil` means unknown, and ownership-gated features then find nothing.
    var currentUserID: UInt32? { get }

    /// `lstat` semantics: a symlink reports `.symlink`, not its target. `nil` if missing.
    func attributes(atPath path: String) -> FileAttributes?

    /// Names (not paths) of directory entries, unsorted.
    func contentsOfDirectory(atPath path: String) throws -> [String]

    /// Raw symlink destination, possibly relative.
    func destinationOfSymbolicLink(atPath path: String) throws -> String

    /// `realpath(3)`: fully resolved absolute path, or `nil` if any link is broken.
    func resolvingSymlinks(atPath path: String) -> String?

    /// Follows symlinks. `true` for executable regular files.
    func isExecutableFile(atPath path: String) -> Bool

    func isWritable(atPath path: String) -> Bool

    /// Reads at most `maxBytes` bytes (all when `nil`).
    func readData(atPath path: String, maxBytes: Int?) throws -> Data
}

extension FileSystem {
    public var currentUserID: UInt32? { nil }

    public func exists(atPath path: String) -> Bool { attributes(atPath: path) != nil }

    public func isDirectory(atPath path: String) -> Bool {
        guard let attributes = attributes(atPath: path) else { return false }
        if attributes.kind == .directory { return true }
        if attributes.kind == .symlink, let resolved = resolvingSymlinks(atPath: path) {
            return self.attributes(atPath: resolved)?.kind == .directory
        }
        return false
    }

    /// Replaces the home directory prefix with `~` for display and export (§172).
    public func abbreviatingHome(_ path: String) -> String {
        PathRedaction.abbreviatingHome(path, home: homeDirectory)
    }
}

public enum PathRedaction {
    public static func abbreviatingHome(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
