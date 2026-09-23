import Darwin
import Foundation

/// Thin wrappers over the POSIX calls shared by the file system and the process runner.
enum POSIXFile {
    static func lstatInfo(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    static func statInfo(_ path: String) -> stat? {
        var info = stat()
        return stat(path, &info) == 0 ? info : nil
    }

    static func kind(of info: stat) -> FileType {
        switch info.st_mode & S_IFMT {
        case S_IFREG: .regular
        case S_IFDIR: .directory
        case S_IFLNK: .symlink
        default: .other
        }
    }

    enum FileType {
        case regular, directory, symlink, other
    }

    /// Follows symlinks; `true` only for regular files the current user may execute.
    static func isExecutableRegularFile(_ path: String) -> Bool {
        guard let info = statInfo(path), kind(of: info) == .regular else { return false }
        return access(path, X_OK) == 0
    }

    static func isDirectory(_ path: String) -> Bool {
        guard let info = statInfo(path) else { return false }
        return kind(of: info) == .directory
    }

    static func modificationDate(_ info: stat) -> Date {
        date(info.st_mtimespec)
    }

    static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    static func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
