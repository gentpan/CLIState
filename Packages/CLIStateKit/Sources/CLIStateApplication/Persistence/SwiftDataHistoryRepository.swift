import CLIStateDomain
import Foundation
import SwiftData

/// SwiftData row for one operation CLIState ran. Only commands, versions and
/// status are stored — never command output or environment (§147).
@Model
final class CommandHistoryRecord {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var finishedAt: Date?
    var status: String
    var providerID: String
    var exitCode: Int32?
    /// JSON-encoded `CommandHistoryEntry` for the fields that don't need querying.
    var payload: Data

    init(id: UUID, startedAt: Date, finishedAt: Date?, status: String, providerID: String, exitCode: Int32?, payload: Data) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.providerID = providerID
        self.exitCode = exitCode
        self.payload = payload
    }
}

@ModelActor
public actor SwiftDataHistoryRepository: CommandHistoryRepository {
    /// `~/Library/Application Support/CLIState/history.store`, or in-memory for tests.
    public static func make(inMemory: Bool = false) throws -> SwiftDataHistoryRepository {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("CLIState", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            configuration = ModelConfiguration(url: support.appendingPathComponent("history.store"))
        }
        let container = try ModelContainer(for: CommandHistoryRecord.self, configurations: configuration)
        return SwiftDataHistoryRepository(modelContainer: container)
    }

    public func entries(limit: Int) async throws -> [CommandHistoryEntry] {
        var descriptor = FetchDescriptor<CommandHistoryRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { try? Self.decoder.decode(CommandHistoryEntry.self, from: $0.payload) }
    }

    public func upsert(_ entry: CommandHistoryEntry) async throws {
        let payload = try Self.encoder.encode(entry)
        let id = entry.id
        let existing = try modelContext.fetch(FetchDescriptor<CommandHistoryRecord>(predicate: #Predicate { $0.id == id })).first
        if let existing {
            existing.finishedAt = entry.finishedAt
            existing.status = entry.status.rawValue
            existing.exitCode = entry.exitCode
            existing.payload = payload
        } else {
            modelContext.insert(CommandHistoryRecord(
                id: entry.id,
                startedAt: entry.startedAt,
                finishedAt: entry.finishedAt,
                status: entry.status.rawValue,
                providerID: entry.providerID.rawValue,
                exitCode: entry.exitCode,
                payload: payload
            ))
        }
        try modelContext.save()
    }

    /// Rows still `running` at launch belong to a previous process that died mid-operation.
    public func markInterruptedEntries() async throws {
        let running = CommandHistoryEntry.Status.running.rawValue
        for record in try modelContext.fetch(FetchDescriptor<CommandHistoryRecord>(predicate: #Predicate { $0.status == running })) {
            guard var entry = try? Self.decoder.decode(CommandHistoryEntry.self, from: record.payload) else { continue }
            entry.status = .interrupted
            record.status = entry.status.rawValue
            record.payload = try Self.encoder.encode(entry)
        }
        try modelContext.save()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
