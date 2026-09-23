import CLIStateDomain
import Foundation

enum JSONParsing {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, providerID: ProviderID, what: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ProviderError.parsingFailed(providerID, what: what)
        }
    }
}

/// Decodes an array, skipping elements that fail instead of failing the whole
/// inventory because of one odd entry (§175).
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(DiscardedValue.self)
            }
        }
        self.elements = elements
    }
}

/// Consumes one JSON value of any shape.
struct DiscardedValue: Decodable {
    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            while !unkeyed.isAtEnd { _ = try unkeyed.decode(DiscardedValue.self) }
        } else if let keyed = try? decoder.container(keyedBy: AnyCodingKey.self) {
            for key in keyed.allKeys { _ = try keyed.decode(DiscardedValue.self, forKey: key) }
        }
        // Scalars and null need no consumption beyond the attempt above.
    }
}

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension KeyedDecodingContainer {
    /// `nil` for missing keys, `null` and values of an unexpected type.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// Decodes a JSON object, skipping values that fail to decode.
struct LossyDictionary<Value: Decodable>: Decodable {
    var values: [String: Value]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var values: [String: Value] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(Value.self, forKey: key) {
                values[key.stringValue] = value
            }
        }
        self.values = values
    }
}
