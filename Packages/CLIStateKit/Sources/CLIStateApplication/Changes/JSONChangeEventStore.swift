import CLIStateDomain
import Foundation

/// Change timeline kept as one JSON file next to the snapshot, replaced atomically.
/// Bounded by age and total change count. Reads tolerate rows written by other
/// versions; if the file can't be read or written, events stay in memory for the session.
public actor JSONChangeEventStore: EnvironmentChangeRepository {
    public static let maxAge: TimeInterval = 180 * 24 * 3600
    public static let maxChanges = 5_000

    private let fileURL: URL?
    private let maxAge: TimeInterval
    private let maxChanges: Int
    private let clock: @Sendable () -> Date

    private var loaded = false
    private var stored = StoredTimeline()

    /// - Parameter fileURL: `nil` keeps everything in memory (probe, tests).
    public init(fileURL: URL?, maxAge: TimeInterval = JSONChangeEventStore.maxAge, maxChanges: Int = JSONChangeEventStore.maxChanges, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.maxAge = maxAge
        self.maxChanges = maxChanges
        self.clock = clock
    }

    /// `~/Library/Application Support/CLIState/changes.json`
    public static func defaultFileURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("CLIState", isDirectory: true).appendingPathComponent("changes.json")
    }

    /// Reads a timeline file without pruning, quarantining or writing anything (probe).
    public static func readEvents(fileURL: URL) throws -> [EnvironmentChangeEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let stored = try decoder.decode(StoredTimeline.self, from: Data(contentsOf: fileURL))
        return stored.events.sorted { $0.detectedAt > $1.detectedAt }
    }

    public func events(since: Date?) async -> [EnvironmentChangeEvent] {
        loadIfNeeded()
        let events = stored.events.sorted { $0.detectedAt > $1.detectedAt }
        guard let since else { return events }
        return events.filter { $0.detectedAt >= since }
    }

    public func hasEvents() async -> Bool {
        loadIfNeeded()
        return stored.baselineAt != nil || !stored.events.isEmpty
    }

    public func append(_ event: EnvironmentChangeEvent) async {
        loadIfNeeded()
        if event.isBaseline, stored.baselineAt == nil { stored.baselineAt = event.detectedAt }
        stored.events.append(event)
        prune()
        persist()
    }

    // MARK: Bounds

    private func prune() {
        let cutoff = clock().addingTimeInterval(-maxAge)
        var events = stored.events.filter { $0.detectedAt >= cutoff }.sorted { $0.detectedAt < $1.detectedAt }
        var total = events.reduce(0) { $0 + $1.changes.count }
        // Whole events go, oldest first; a single oversized event is truncated.
        while total > maxChanges, let oldest = events.first {
            if events.count > 1 {
                total -= oldest.changes.count
                events.removeFirst()
            } else {
                events[0].changes = Array(oldest.changes.prefix(maxChanges))
                total = events[0].changes.count
            }
        }
        stored.events = events
    }

    // MARK: File

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            stored = try Self.decoder.decode(StoredTimeline.self, from: data)
            prune()
        } catch {
            // Keep the unreadable file for diagnostics and start a new timeline.
            let target = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.moveItem(at: fileURL, to: target)
        }
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(stored).write(to: fileURL, options: [.atomic])
        } catch {
            // In-memory state stays authoritative for this session.
        }
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

/// On-disk shape. `baselineAt` survives pruning so a quiet half-year doesn't
/// produce a second baseline.
struct StoredTimeline: Codable, Sendable {
    static let currentVersion = 1

    var version = StoredTimeline.currentVersion
    var baselineAt: Date?
    var events: [EnvironmentChangeEvent] = []

    init() {}

    private enum CodingKeys: String, CodingKey { case version, baselineAt, events }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? StoredTimeline.currentVersion
        baselineAt = try? container.decodeIfPresent(Date.self, forKey: .baselineAt)
        let lossy = try container.decodeIfPresent([LossyElement<EnvironmentChangeEvent>].self, forKey: .events) ?? []
        events = lossy.compactMap(\.value)
    }
}
