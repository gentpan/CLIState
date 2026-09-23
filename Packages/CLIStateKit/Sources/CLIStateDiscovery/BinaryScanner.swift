import CLIStateDomain
import Foundation

/// Lists executables in `.ok` PATH directories (§109, §110). Only reads
/// metadata; never executes or opens anything it finds.
public struct BinaryScanner: Sendable {
    private let fileSystem: FileSystem
    private let protected: ProtectedLocations
    private let maximumConcurrentDirectories: Int

    public init(fileSystem: FileSystem, maximumConcurrentDirectories: Int = 8) {
        self.fileSystem = fileSystem
        self.protected = ProtectedLocations(home: fileSystem.homeDirectory)
        self.maximumConcurrentDirectories = max(1, maximumConcurrentDirectories)
    }

    /// Directories are read concurrently; the result depends only on the inputs.
    public func scan(_ entries: [PATHEntry]) async -> BinaryInventory {
        await scan(entries, listings: [:])
    }

    /// Uses `listings` (from `PATHResolver`) instead of reading those directories again.
    func scan(_ entries: [PATHEntry], listings: [Int: DirectoryListing]) async -> BinaryInventory {
        let directories = entries.filter { $0.status == .ok }.sorted { $0.priority < $1.priority }
        guard !directories.isEmpty else { return BinaryInventory() }

        let fileSystem = fileSystem
        let protected = protected
        let limit = maximumConcurrentDirectories
        let scans = await withTaskGroup(of: (Int, DirectoryScan).self, returning: [DirectoryScan].self) { group in
            var results = [DirectoryScan](repeating: DirectoryScan(), count: directories.count)
            var next = 0
            func enqueue(_ index: Int) {
                let entry = directories[index]
                let listing = listings[entry.priority]
                group.addTask {
                    (index, Self.scanDirectory(entry, listing: listing, fileSystem: fileSystem, protected: protected))
                }
            }
            while next < min(limit, directories.count) {
                enqueue(next)
                next += 1
            }
            while let (index, scan) = await group.next() {
                results[index] = scan
                if next < directories.count {
                    enqueue(next)
                    next += 1
                }
            }
            return results
        }

        var candidatesByName: [String: [BinaryCandidate]] = [:]
        var broken: [BrokenSymlink] = []
        for scan in scans {
            for candidate in scan.candidates {
                candidatesByName[candidate.name, default: []].append(candidate)
            }
            broken += scan.brokenSymlinks
        }
        let groups = candidatesByName.mapValues { BinaryGroup(executableName: $0[0].name, candidates: $0) }
        return BinaryInventory(groups: groups, brokenSymlinks: broken)
    }

    /// Fills `executableCount` for every entry from a finished scan.
    public static func annotate(_ entries: [PATHEntry], with inventory: BinaryInventory) -> [PATHEntry] {
        var counts: [Int: Int] = [:]
        for group in inventory.groups.values {
            for candidate in group.candidates {
                counts[candidate.pathPriority, default: 0] += 1
            }
        }
        return entries.map { entry in
            var entry = entry
            entry.executableCount = counts[entry.priority] ?? 0
            return entry
        }
    }

    // MARK: Private

    struct DirectoryScan: Sendable {
        var candidates: [BinaryCandidate] = []
        var brokenSymlinks: [BrokenSymlink] = []
    }

    static func scanDirectory(
        _ entry: PATHEntry,
        listing: DirectoryListing?,
        fileSystem: FileSystem,
        protected: ProtectedLocations
    ) -> DirectoryScan {
        var scan = DirectoryScan()
        let directory = entry.normalizedPath
        guard !protected.contains(directory) else { return scan }
        let names: [String]
        let realDirectory: String
        if let listing {
            names = listing.names
            realDirectory = listing.realPath
        } else {
            guard let resolved = fileSystem.resolvingSymlinks(atPath: directory),
                  !protected.contains(resolved),
                  let listed = try? fileSystem.contentsOfDirectory(atPath: resolved)
            else { return scan }
            names = listed
            realDirectory = resolved
        }

        for name in names.sorted() {
            if Task.isCancelled { break }
            guard !name.hasPrefix("."), !name.contains("/") else { continue }
            let path = join(directory, name)
            // Metadata is read through the directory's realpath: same answer as `lstat`
            // on `path`, without relying on the port to follow intermediate links.
            let physical = join(realDirectory, name)
            guard let attributes = fileSystem.attributes(atPath: physical) else { continue }

            switch attributes.kind {
            case .file:
                guard fileSystem.isExecutableFile(atPath: physical) else { continue }
                scan.candidates.append(BinaryCandidate(
                    name: name,
                    path: path,
                    pathPriority: entry.priority,
                    isSymlink: false,
                    resolvedPath: physical,
                    size: attributes.size,
                    modifiedAt: attributes.modifiedAt
                ))

            case .symlink:
                let destination = try? fileSystem.destinationOfSymbolicLink(atPath: physical)
                if let destination {
                    let target = absolute(destination, relativeTo: realDirectory)
                    if protected.contains(target) {
                        // Resolving would stat inside a TCC folder (F12). The shell would
                        // still run it, so report it with its unverified destination.
                        scan.candidates.append(BinaryCandidate(
                            name: name, path: path, pathPriority: entry.priority, isSymlink: true, resolvedPath: target
                        ))
                        continue
                    }
                }
                guard let resolved = fileSystem.resolvingSymlinks(atPath: physical) else {
                    scan.brokenSymlinks.append(BrokenSymlink(path: path, destination: destination ?? "", pathPriority: entry.priority))
                    continue
                }
                guard fileSystem.isExecutableFile(atPath: resolved),
                      let target = fileSystem.attributes(atPath: resolved), target.kind == .file
                else { continue }
                scan.candidates.append(BinaryCandidate(
                    name: name,
                    path: path,
                    pathPriority: entry.priority,
                    isSymlink: true,
                    resolvedPath: resolved,
                    size: target.size,
                    modifiedAt: target.modifiedAt
                ))

            case .directory, .other:
                continue
            }
        }
        return scan
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    /// Joins without following links, so it is safe to call before a TCC check.
    static func absolute(_ destination: String, relativeTo directory: String) -> String {
        let combined = destination.hasPrefix("/") ? destination : join(directory, destination)
        return PathNormalization.lexical(combined)
    }
}

/// Names in one PATH directory, read once by `PATHResolver`.
struct DirectoryListing: Sendable {
    var realPath: String
    var names: [String]
}
