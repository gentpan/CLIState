import Darwin
import Foundation

/// Executes `OperationStep.moveToTrash`: a recoverable move into the user's Trash.
/// Never deletes anything (§159).
public struct LocalTrash: Sendable {
    public init() {}

    /// Moves the item at the absolute `path` to the Trash and returns where it ended up.
    /// A symlink is trashed itself; its target is never touched.
    public func moveToTrash(atPath path: String) throws -> URL {
        guard path.hasPrefix("/"), let info = POSIXFile.lstatInfo(path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        // Pass the real kind explicitly: letting URL probe the path would follow a
        // symlink to a directory and add a trailing slash that resolves the link.
        let url = URL(fileURLWithPath: path, isDirectory: POSIXFile.kind(of: info) == .directory)
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let trashed = resultingURL as URL? else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        return trashed
    }
}
