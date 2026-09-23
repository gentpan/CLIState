import CLIStateDomain
import Foundation

/// Parses endoflife.date responses. Tolerates both the v1 API
/// (`{"result": {"releases": [...]}}`) and the legacy `/api/<product>.json`
/// array, unknown fields, numeric cycle names and boolean-or-date fields.
public enum EndOfLifeDecoder {
    public static func cycles(from data: Data) -> [EndOfLifeCycle]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let object = json as? [String: Any] {
            let result = object["result"] as? [String: Any] ?? object
            guard let releases = result["releases"] as? [[String: Any]] else { return nil }
            return releases.compactMap(v1Cycle)
        }
        if let rows = json as? [[String: Any]] {
            return rows.compactMap(legacyCycle)
        }
        return nil
    }

    private static func v1Cycle(_ row: [String: Any]) -> EndOfLifeCycle? {
        guard let name = string(row["name"]) else { return nil }
        let latest = (row["latest"] as? [String: Any]).flatMap { string($0["name"]) } ?? string(row["latest"])
        return EndOfLifeCycle(
            name: name,
            releaseDate: date(row["releaseDate"]),
            endOfLifeDate: date(row["eolFrom"]),
            isEndOfLife: row["isEol"] as? Bool,
            latestVersion: latest,
            isLTS: row["isLts"] as? Bool
        )
    }

    private static func legacyCycle(_ row: [String: Any]) -> EndOfLifeCycle? {
        guard let name = string(row["cycle"]) else { return nil }
        // `eol` and `lts` are either a date string or a boolean.
        let lts: Bool? = (row["lts"] as? Bool) ?? (date(row["lts"]) != nil ? true : nil)
        return EndOfLifeCycle(
            name: name,
            releaseDate: date(row["releaseDate"]),
            endOfLifeDate: date(row["eol"]),
            isEndOfLife: row["eol"] as? Bool,
            latestVersion: string(row["latest"]),
            isLTS: lts
        )
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text.isEmpty ? nil : text
        // JSONSerialization yields NSNumber for both numbers and booleans.
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): return number.stringValue
        default: return nil
        }
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, text.count >= 10 else { return nil }
        return try? Date(String(text.prefix(10)), strategy: dayFormat)
    }

    static let dayFormat = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()
}

/// Fetches one product from endoflife.date over HTTPS (read-only GET).
public struct EndOfLifeSource: Sendable {
    private let http: any HTTPFetching
    private let timeout: Duration

    public static let baseURL = URL(string: "https://endoflife.date")!

    public init(http: any HTTPFetching, timeout: Duration = .seconds(10)) {
        self.http = http
        self.timeout = timeout
    }

    /// Slugs are constants from the registry, but never build a URL from anything else.
    public static func isValidSlug(_ slug: String) -> Bool {
        !slug.isEmpty && slug.count <= 64 && slug.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
            && !slug.hasPrefix("-")
    }

    public static func v1URL(_ slug: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/api/v1/products/\(slug)/"
        return components.url!
    }

    public static func legacyURL(_ slug: String) -> URL {
        baseURL.appending(path: "api/\(slug).json")
    }

    public enum FetchError: Error, Equatable, Sendable {
        case invalidSlug
        case httpStatus(Int)
        case unreadable
    }

    /// v1 first; the legacy endpoint only when v1 fails or can't be parsed.
    public func fetch(_ slug: String, now: Date) async throws -> EndOfLifeProduct {
        guard Self.isValidSlug(slug) else { throw FetchError.invalidSlug }
        var lastError: any Error = FetchError.unreadable
        for url in [Self.v1URL(slug), Self.legacyURL(slug)] {
            do {
                let response = try await http.get(url, timeout: timeout)
                guard (200..<300).contains(response.statusCode) else {
                    lastError = FetchError.httpStatus(response.statusCode)
                    continue
                }
                guard let cycles = EndOfLifeDecoder.cycles(from: response.body), !cycles.isEmpty else {
                    lastError = FetchError.unreadable
                    continue
                }
                return EndOfLifeProduct(slug: slug, cycles: cycles, fetchedAt: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
