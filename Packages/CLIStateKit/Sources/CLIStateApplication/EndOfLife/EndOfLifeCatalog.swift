import CLIStateDomain
import CLIStateEngine
import CLIStateInfrastructure
import Foundation

/// Release-cycle data per product, cached for 7 days in Application Support.
/// Fast scans only read the cache; deep scans refresh stale entries. Network
/// failures never surface in the UI: the last cached data (if any) is used and
/// the error is logged and kept for diagnostics.
public actor EndOfLifeCatalog: EndOfLifeProviding {
    public static let maxAge: TimeInterval = 7 * 24 * 3600
    /// Don't retry a failed product on every deep scan.
    public static let retryDelay: TimeInterval = 3600

    private let source: EndOfLifeSource
    private let directory: URL?
    private let clock: @Sendable () -> Date

    private var memory: [String: EndOfLifeProduct] = [:]
    private var inFlight: [String: Task<EndOfLifeProduct?, Never>] = [:]
    private var failedAt: [String: Date] = [:]
    /// Last fetch error per product, for diagnostics.
    public private(set) var lastErrors: [String: String] = [:]

    /// - Parameter directory: `nil` keeps the cache in memory only.
    public init(source: EndOfLifeSource, directory: URL?, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.directory = directory
        self.clock = clock
    }

    /// `~/Library/Application Support/CLIState/EndOfLife/`
    public static func defaultDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("CLIState", isDirectory: true).appendingPathComponent("EndOfLife", isDirectory: true)
    }

    public func product(_ slug: String, allowNetwork: Bool) async -> EndOfLifeProduct? {
        guard EndOfLifeSource.isValidSlug(slug) else { return nil }
        let cached = cachedProduct(slug)
        let now = clock()
        if let cached, now.timeIntervalSince(cached.fetchedAt) < Self.maxAge { return cached }
        guard allowNetwork else { return cached }
        if let failed = failedAt[slug], now.timeIntervalSince(failed) < Self.retryDelay { return cached }

        if let running = inFlight[slug] { return await running.value ?? cached }
        let source = self.source
        let task = Task { () -> EndOfLifeProduct? in
            do {
                return try await source.fetch(slug, now: now)
            } catch {
                self.recordFailure(slug, error: error)
                return nil
            }
        }
        inFlight[slug] = task
        let fetched = await task.value
        inFlight[slug] = nil
        guard let fetched else { return cached }
        failedAt[slug] = nil
        lastErrors[slug] = nil
        memory[slug] = fetched
        save(fetched)
        return fetched
    }

    private func recordFailure(_ slug: String, error: any Error) {
        failedAt[slug] = clock()
        lastErrors[slug] = String(describing: error)
        AppLog.update.notice("end-of-life data for \(slug, privacy: .public) unavailable: \(String(describing: error), privacy: .public)")
    }

    // MARK: Disk

    private func cachedProduct(_ slug: String) -> EndOfLifeProduct? {
        if let product = memory[slug] { return product }
        guard let url = fileURL(slug), let data = try? Data(contentsOf: url),
              let product = try? Self.decoder.decode(EndOfLifeProduct.self, from: data), product.slug == slug
        else { return nil }
        memory[slug] = product
        return product
    }

    private func save(_ product: EndOfLifeProduct) {
        guard let directory, let url = fileURL(product.slug) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(product).write(to: url, options: [.atomic])
        } catch {
            // Memory cache still serves this session.
        }
    }

    private func fileURL(_ slug: String) -> URL? {
        directory?.appendingPathComponent("\(slug).json")
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
