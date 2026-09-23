import Foundation
import Security

/// API keys, one per provider. Implementations never log or persist keys elsewhere.
public protocol AISecretStore: Sendable {
    func apiKey(for provider: AIProviderKind) throws -> String?
    func setAPIKey(_ key: String, for provider: AIProviderKind) throws
    func removeAPIKey(for provider: AIProviderKind) throws
    /// Existence check that doesn't read the secret (no Keychain access prompt).
    func hasAPIKey(for provider: AIProviderKind) -> Bool
}

extension AISecretStore {
    public func hasAPIKey(for provider: AIProviderKind) -> Bool {
        ((try? apiKey(for: provider)) ?? nil)?.isEmpty == false
    }
}

/// Generic-password items in the login keychain: service `com.clistate.app.ai`,
/// account = provider id.
public struct KeychainAISecretStore: AISecretStore {
    public static let service = "com.clistate.app.ai"

    public init() {}

    private func baseQuery(_ provider: AIProviderKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.secretAccount,
        ]
    }

    public func apiKey(for provider: AIProviderKind) throws -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw AIError(.keychain(status: status))
        }
    }

    public func hasAPIKey(for provider: AIProviderKind) -> Bool {
        var query = baseQuery(provider)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func setAPIKey(_ key: String, for provider: AIProviderKind) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try removeAPIKey(for: provider)
            return
        }
        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(provider) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(provider)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "CLI State AI API key (\(provider.secretAccount))"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AIError(.keychain(status: status)) }
    }

    public func removeAPIKey(for provider: AIProviderKind) throws {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIError(.keychain(status: status))
        }
    }
}

/// For tests and previews.
public final class InMemoryAISecretStore: AISecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [AIProviderKind: String]

    public init(_ keys: [AIProviderKind: String] = [:]) {
        self.keys = keys
    }

    public func apiKey(for provider: AIProviderKind) throws -> String? {
        lock.withLock { keys[provider] }
    }

    public func setAPIKey(_ key: String, for provider: AIProviderKind) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock { keys[provider] = trimmed.isEmpty ? nil : trimmed }
    }

    public func removeAPIKey(for provider: AIProviderKind) throws {
        _ = lock.withLock { keys.removeValue(forKey: provider) }
    }
}
