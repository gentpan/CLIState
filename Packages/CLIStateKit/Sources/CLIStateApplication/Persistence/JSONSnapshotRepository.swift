import CLIStateDomain
import Foundation

/// Stores the last `EnvironmentSnapshot` as one JSON file, replaced atomically
/// so a crash mid-write never leaves a half-written snapshot (§218, C13).
public actor JSONSnapshotRepository: SnapshotRepository {
    private let fileURL: URL
    private let clock: @Sendable () -> Date

    public init(fileURL: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.clock = clock
    }

    /// `~/Library/Application Support/CLIState/snapshot.json`
    public static func defaultFileURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("CLIState", isDirectory: true).appendingPathComponent("snapshot.json")
    }

    /// `nil` when there is no usable cache. A file that doesn't decode (corruption, a
    /// schema change) is moved aside rather than deleted, and the app starts from a fresh scan.
    public func load() async throws -> EnvironmentSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard let snapshot = try? Self.decoder.decode(EnvironmentSnapshot.self, from: data),
              snapshot.schemaVersion == EnvironmentSnapshot.currentSchemaVersion
        else {
            moveAside()
            return nil
        }
        return snapshot
    }

    public func save(_ snapshot: EnvironmentSnapshot) async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Renames the unreadable cache to `snapshot.json.corrupt-<UTC timestamp>` for
    /// diagnostics, never replacing an earlier copy. If the rename fails, the next save
    /// overwrites the file, which is no worse than keeping it.
    @discardableResult
    func moveAside() -> URL? {
        let directory = fileURL.deletingLastPathComponent()
        let base = "\(fileURL.lastPathComponent).corrupt-\(Self.timestamp(clock()))"
        var target = directory.appendingPathComponent(base)
        var attempt = 1
        while FileManager.default.fileExists(atPath: target.path) {
            attempt += 1
            target = directory.appendingPathComponent("\(base)-\(attempt)")
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: target)
            return target
        } catch {
            return nil
        }
    }

    /// `20260913T031500Z`: sortable and free of `:` for Finder.
    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false).timeSeparator(.omitted).timeZone(separator: .omitted))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
