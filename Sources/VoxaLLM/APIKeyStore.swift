import Foundation
import Security
import VoxaCore

public protocol APIKeyProviding: Sendable {
    /// The stored key. Throws `LLMError.missingAPIKey` when there isn't one.
    func apiKey() async throws -> String
}

public enum APIKeyError: Error, Sendable, Equatable {
    case empty
    case containsWhitespace
    case keychain(Int32)
}

extension APIKeyError: UserFacingConvertible {
    public var userFacing: UserFacingError {
        switch self {
        case .empty:
            UserFacingError(title: L10n.LLM.keyEmptyTitle, detail: L10n.LLM.keyEmptyDetail)
        case .containsWhitespace:
            UserFacingError(title: L10n.LLM.keyMalformedTitle, detail: L10n.LLM.keyMalformedDetail)
        case .keychain(let status):
            UserFacingError(title: L10n.LLM.keychainTitle, detail: L10n.LLM.keychainDetail(Int(status)))
        }
    }
}

public protocol APIKeyStoring: APIKeyProviding {
    func save(_ key: String) throws
    func delete() throws
    func hasKey() -> Bool
}

extension APIKeyStoring {
    /// Trims surrounding whitespace (a key pasted with a trailing newline is the common mistake) and rejects anything that
    /// still can't be a key.
    static func normalized(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIKeyError.empty }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw APIKeyError.containsWhitespace
        }
        return trimmed
    }
}

/// Stores the key in the macOS Keychain as a generic password: readable only while the Mac is unlocked, never synced to iCloud,
/// never written to preferences, logs or disk in any other form.
public struct KeychainAPIKeyStore: APIKeyStoring {
    private let service: String
    private let account: String

    public init(service: String = "com.rohitsainier.voxa", account: String = "anthropic-api-key") {
        self.service = service
        self.account = account
    }

    private var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ key: String) throws {
        let value = try Self.normalized(key)
        // Replace any existing item: SecItemUpdate would keep the old item's access control.
        SecItemDelete(identity as CFDictionary)

        var attributes = identity
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw APIKeyError.keychain(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIKeyError.keychain(status) }
    }

    public func hasKey() -> Bool {
        // Ask for the item's attributes only. Reading the secret can trigger a Keychain prompt after a rebuild changes the
        // app's signature; checking that it exists never does.
        var query = identity
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func apiKey() async throws -> String {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw LLMError.missingAPIKey }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw APIKeyError.keychain(status)
        }
        return key
    }
}

/// A key held in memory, for tests and developer tools.
public final class InMemoryAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func save(_ key: String) throws {
        let value = try Self.normalized(key)
        lock.withLock { self.key = value }
    }

    public func delete() throws {
        lock.withLock { key = nil }
    }

    public func hasKey() -> Bool {
        lock.withLock { key != nil }
    }

    public func apiKey() async throws -> String {
        guard let key = lock.withLock({ key }) else { throw LLMError.missingAPIKey }
        return key
    }
}
