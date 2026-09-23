import Foundation

/// One release cycle of a product as published by endoflife.date, e.g. Node.js `22`
/// or Python `3.9`.
public struct EndOfLifeCycle: Hashable, Codable, Sendable {
    /// Cycle name: `22`, `3.9`, `8.1`.
    public var name: String
    public var releaseDate: Date?
    /// Date security support ends; `nil` when not announced.
    public var endOfLifeDate: Date?
    /// Explicit flag from the source. Some cycles are EOL without a date.
    public var isEndOfLife: Bool?
    public var latestVersion: String?
    public var isLTS: Bool?

    public init(name: String, releaseDate: Date? = nil, endOfLifeDate: Date? = nil, isEndOfLife: Bool? = nil, latestVersion: String? = nil, isLTS: Bool? = nil) {
        self.name = name
        self.releaseDate = releaseDate
        self.endOfLifeDate = endOfLifeDate
        self.isEndOfLife = isEndOfLife
        self.latestVersion = latestVersion
        self.isLTS = isLTS
    }
}

/// All cycles of one endoflife.date product, newest first.
public struct EndOfLifeProduct: Hashable, Codable, Sendable {
    /// endoflife.date slug: `nodejs`, `python`, `postgresql`.
    public var slug: String
    public var cycles: [EndOfLifeCycle]
    public var fetchedAt: Date

    public init(slug: String, cycles: [EndOfLifeCycle], fetchedAt: Date) {
        self.slug = slug
        self.cycles = cycles
        self.fetchedAt = fetchedAt
    }
}

public enum RuntimeSupportPhase: String, Codable, Sendable, Comparable {
    case supported
    /// Support ends within the reminder window (90 days).
    case endingSoon
    case ended

    private var rank: Int {
        switch self {
        case .supported: 0
        case .endingSoon: 1
        case .ended: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Support state of one installation's release cycle at scan time.
public struct RuntimeSupportStatus: Hashable, Codable, Sendable {
    public var product: String
    public var cycle: String
    public var phase: RuntimeSupportPhase
    public var endOfLifeDate: Date?
    /// Newest released cycle that is still supported, e.g. `24`.
    public var latestSupportedCycle: String?
    /// When the cycle data was fetched from endoflife.date.
    public var checkedAt: Date

    public init(product: String, cycle: String, phase: RuntimeSupportPhase, endOfLifeDate: Date? = nil, latestSupportedCycle: String? = nil, checkedAt: Date) {
        self.product = product
        self.cycle = cycle
        self.phase = phase
        self.endOfLifeDate = endOfLifeDate
        self.latestSupportedCycle = latestSupportedCycle
        self.checkedAt = checkedAt
    }
}

/// Read-only access to release-cycle data. Implementations cache; `allowNetwork`
/// is `true` only for deep scans and explicit update checks.
public protocol EndOfLifeProviding: Sendable {
    func product(_ slug: String, allowNetwork: Bool) async -> EndOfLifeProduct?
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// Read-only HTTPS GET. Implemented by Infrastructure over `URLSession`.
public protocol HTTPFetching: Sendable {
    func get(_ url: URL, timeout: Duration) async throws -> HTTPResponse
}
