import CLIStateDomain
import Darwin
import Foundation

/// The real disk, read-only, using the exact POSIX semantics `FileSystem` documents:
/// `lstat` for attributes, `realpath(3)` for resolution, `access(2)` for permissions.
public struct LocalFileSystem: FileSystem {
    public let homeDirectory: String

    /// `homeDirectory` defaults to the account's home from the password database,
    /// so a modified `$HOME` in the app's own environment doesn't change it.
    public init(homeDirectory: String? = nil) {
        self.homeDirectory = homeDirectory ?? Self.accountHomeDirectory()
    }

    public func attributes(atPath path: String) -> FileAttributes? {
        guard let info = POSIXFile.lstatInfo(path) else { return nil }
        let kind: FileKind = switch POSIXFile.kind(of: info) {
        case .regular: .file
        case .directory: .directory
        case .symlink: .symlink
        case .other: .other
        }
        return FileAttributes(
            kind: kind,
            size: Int64(info.st_size),
            modifiedAt: POSIXFile.modificationDate(info),
            isExecutable: kind == .file && access(path, X_OK) == 0,
            ownerID: info.st_uid,
            accessedAt: POSIXFile.date(info.st_atimespec),
            statusChangedAt: POSIXFile.date(info.st_ctimespec),
            inode: UInt64(info.st_ino),
            linkCount: Int(info.st_nlink)
        )
    }

    public var currentUserID: UInt32? { getuid() }

    public func contentsOfDirectory(atPath path: String) throws -> [String] {
        guard let directory = opendir(path) else { throw POSIXFile.currentError() }
        defer { closedir(directory) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw POSIXFile.currentError() }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(length), as: UTF8.self)
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        return names
    }

    public func destinationOfSymbolicLink(atPath path: String) throws -> String {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) * 4)
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            pointer.withMemoryRebound(to: CChar.self) { readlink(path, $0.baseAddress, $0.count) }
        }
        guard count >= 0 else { throw POSIXFile.currentError() }
        return String(decoding: buffer.prefix(count), as: UTF8.self)
    }

    public func resolvingSymlinks(atPath path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func isExecutableFile(atPath path: String) -> Bool {
        POSIXFile.isExecutableRegularFile(path)
    }

    public func isWritable(atPath path: String) -> Bool {
        access(path, W_OK) == 0
    }

    /// Only regular files are read: FIFOs and devices could block or never end.
    public func readData(atPath path: String, maxBytes: Int?) throws -> Data {
        // O_NONBLOCK keeps open(2) from waiting on a FIFO; it has no effect on regular files.
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXFile.currentError() }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXFile.currentError() }
        switch POSIXFile.kind(of: info) {
        case .regular: break
        case .directory: throw POSIXError(.EISDIR)
        case .symlink, .other: throw POSIXError(.EFTYPE)
        }

        let limit = maxBytes.map { max(0, $0) } ?? Int.max
        var data = Data()
        data.reserveCapacity(min(limit, Int(info.st_size)))
        let chunkSize = 65_536
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 1)
        defer { buffer.deallocate() }

        while data.count < limit {
            let count = read(fd, buffer, min(chunkSize, limit - data.count))
            if count > 0 {
                data.append(buffer.assumingMemoryBound(to: UInt8.self), count: count)
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw POSIXFile.currentError()
            }
        }
        return data
    }

    private static func accountHomeDirectory() -> String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            let home = String(cString: directory)
            if !home.isEmpty { return home }
        }
        return NSHomeDirectory()
    }
}
