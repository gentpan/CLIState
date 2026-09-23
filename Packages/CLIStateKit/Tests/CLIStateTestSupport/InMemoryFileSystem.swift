import CLIStateDomain
import Foundation

/// Deterministic filesystem for Discovery and Engine tests.
///
///     let fs = InMemoryFileSystem(home: "/Users/tester")
///     fs.addExecutable("/opt/homebrew/Cellar/php/8.5.7/bin/php")
///     fs.addSymlink("/opt/homebrew/bin/php", to: "../Cellar/php/8.5.7/bin/php")
public final class InMemoryFileSystem: FileSystem, @unchecked Sendable {
    private enum Node {
        case file(data: Data, executable: Bool, modifiedAt: Date)
        case directory
        case symlink(String)
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = ["/": .directory]
    private var readOnly: Set<String> = []
    private var owners: [String: UInt32] = [:]
    private var accessTimes: [String: Date] = [:]
    private var changeTimes: [String: Date] = [:]
    /// Paths that are hard links of another path's inode.
    private var inodes: [String: UInt64] = [:]
    private var nextInode: UInt64 = 1
    public let homeDirectory: String
    /// Every node belongs to this user unless `setOwner` says otherwise.
    public let currentUserID: UInt32?

    public init(home: String = "/Users/tester", currentUserID: UInt32? = 501) {
        self.homeDirectory = home
        self.currentUserID = currentUserID
        addDirectory(home)
    }

    // MARK: Building

    public func addDirectory(_ path: String) {
        let path = Self.normalize(path)
        lock.withLock { createParents(of: path); nodes[path] = .directory }
    }

    public func addFile(_ path: String, contents: Data = Data(), executable: Bool = false, modifiedAt: Date = Date(timeIntervalSince1970: 0)) {
        let path = Self.normalize(path)
        lock.withLock { createParents(of: path); nodes[path] = .file(data: contents, executable: executable, modifiedAt: modifiedAt); inodes[path] = nil }
    }

    public func addExecutable(_ path: String, contents: String = "#!/bin/sh\n") {
        addFile(path, contents: Data(contents.utf8), executable: true)
    }

    public func addSymlink(_ path: String, to destination: String) {
        let path = Self.normalize(path)
        lock.withLock { createParents(of: path); nodes[path] = .symlink(destination) }
    }

    public func markReadOnly(_ path: String) {
        let path = Self.normalize(path)
        lock.withLock { _ = readOnly.insert(path) }
    }

    public func setOwner(_ path: String, uid: UInt32) {
        let path = Self.normalize(path)
        lock.withLock { owners[path] = uid }
    }

    /// Access time reported by `attributes`; files have none until set.
    public func setAccessedAt(_ path: String, _ date: Date?) {
        let path = Self.normalize(path)
        lock.withLock { accessTimes[path] = date }
    }

    /// Inode change time reported by `attributes`; files have none until set.
    public func setStatusChangedAt(_ path: String, _ date: Date?) {
        let path = Self.normalize(path)
        lock.withLock { changeTimes[path] = date }
    }

    /// A second name for the file at `existing`: same contents and inode, link count 2+.
    public func addHardLink(_ path: String, to existing: String) {
        let path = Self.normalize(path)
        let existing = Self.normalize(existing)
        lock.withLock {
            guard case .file = nodes[existing] else { return }
            createParents(of: path)
            nodes[path] = nodes[existing]
            let inode = inode(of: existing)
            inodes[path] = inode
        }
    }

    public func remove(_ path: String) {
        let path = Self.normalize(path)
        lock.withLock { nodes[path] = nil; inodes[path] = nil }
    }

    // MARK: FileSystem

    public func attributes(atPath path: String) -> FileAttributes? {
        let path = Self.normalize(path)
        return lock.withLock {
            // lstat(2) follows symlinks in every component but the last.
            let path = lstatPath(path)
            let owner = owners[path] ?? currentUserID
            switch nodes[path] {
            case nil: return nil
            case .directory: return FileAttributes(kind: .directory, ownerID: owner)
            case let .symlink(destination): return FileAttributes(kind: .symlink, size: Int64(destination.utf8.count), ownerID: owner)
            case let .file(data, executable, modifiedAt):
                let inode = inode(of: path)
                return FileAttributes(
                    kind: .file, size: Int64(data.count), modifiedAt: modifiedAt, isExecutable: executable, ownerID: owner,
                    accessedAt: accessTimes[path], statusChangedAt: changeTimes[path],
                    inode: inode, linkCount: inodes.values.filter { $0 == inode }.count
                )
            }
        }
    }

    public func contentsOfDirectory(atPath path: String) throws -> [String] {
        guard let resolved = resolvingSymlinks(atPath: path) else { throw CocoaError(.fileReadNoSuchFile) }
        return try lock.withLock {
            guard case .directory = nodes[resolved] else { throw CocoaError(.fileReadNoSuchFile) }
            let prefix = resolved == "/" ? "/" : resolved + "/"
            return nodes.keys.compactMap { key in
                guard key.hasPrefix(prefix), key != resolved else { return nil }
                let rest = key.dropFirst(prefix.count)
                return rest.contains("/") ? nil : String(rest)
            }
        }
    }

    public func destinationOfSymbolicLink(atPath path: String) throws -> String {
        let path = Self.normalize(path)
        return try lock.withLock {
            guard case let .symlink(destination) = nodes[path] else { throw CocoaError(.fileReadUnknown) }
            return destination
        }
    }

    public func resolvingSymlinks(atPath path: String) -> String? {
        lock.withLock { resolve(Self.normalize(path), depth: 0) }
    }

    public func isExecutableFile(atPath path: String) -> Bool {
        guard let resolved = resolvingSymlinks(atPath: path) else { return false }
        return lock.withLock {
            if case let .file(_, executable, _) = nodes[resolved] { return executable }
            return false
        }
    }

    public func isWritable(atPath path: String) -> Bool {
        let path = Self.normalize(path)
        return lock.withLock { nodes[path] != nil && !readOnly.contains(path) }
    }

    public func readData(atPath path: String, maxBytes: Int?) throws -> Data {
        guard let resolved = resolvingSymlinks(atPath: path) else { throw CocoaError(.fileReadNoSuchFile) }
        return try lock.withLock {
            guard case let .file(data, _, _) = nodes[resolved] else { throw CocoaError(.fileReadNoSuchFile) }
            return maxBytes.map { Data(data.prefix($0)) } ?? data
        }
    }

    // MARK: Private

    private func createParents(of path: String) {
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty, nodes[parent] == nil {
            nodes[parent] = .directory
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    /// Assigns inodes on first use. Caller holds the lock.
    private func inode(of path: String) -> UInt64 {
        if let inode = inodes[path] { return inode }
        let inode = nextInode
        nextInode += 1
        inodes[path] = inode
        return inode
    }

    /// `path` with its parent directory resolved. Caller holds the lock.
    private func lstatPath(_ path: String) -> String {
        guard path != "/", nodes[path] == nil else { return path }
        let parent = (path as NSString).deletingLastPathComponent
        guard let resolvedParent = resolve(parent, depth: 0), resolvedParent != parent else { return path }
        return (resolvedParent as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    /// Resolves every component, like realpath(3). Caller holds the lock.
    private func resolve(_ path: String, depth: Int) -> String? {
        guard depth < 32 else { return nil }
        var resolved = "/"
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let candidate = resolved == "/" ? "/" + component : resolved + "/" + component
            switch nodes[candidate] {
            case nil:
                return nil
            case let .symlink(destination):
                let base = destination.hasPrefix("/") ? destination : (resolved as NSString).appendingPathComponent(destination)
                let remainder = components[(index + 1)...].joined(separator: "/")
                let next = remainder.isEmpty ? base : (base as NSString).appendingPathComponent(remainder)
                return resolve(Self.normalize(next), depth: depth + 1)
            case .directory, .file:
                resolved = candidate
            }
        }
        return resolved
    }

    static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return PathNormalization.lexical(expanded.isEmpty ? "/" : expanded)
    }
}
