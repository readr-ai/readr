#if canImport(Security)
import Foundation
import Security

/// A `CredentialStore` that persists secrets in the system Keychain.
///
/// This is the **only** place provider secrets are persisted. Items are stored as
/// `kSecClassGenericPassword` entries protected with
/// `kSecAttrAccessibleAfterFirstUnlock`, so they are readable after the first
/// device unlock following a boot and remain encrypted at rest.
///
/// Secrets must NEVER be written to `UserDefaults`, plists, app-group containers,
/// log output, or any other location — only here.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    /// Service identifier used as `kSecAttrService` for every item this store owns.
    private let service: String

    public init(service: String = "com.readr.credentials") {
        self.service = service
    }

    // MARK: - CredentialStore

    public func save(_ credentials: Credentials, for kind: ProviderInfo.Kind) throws {
        let json = try JSONEncoder().encode(credentials)

        // Replace semantics: remove any existing item before adding the new one so
        // `SecItemAdd` cannot fail with `errSecDuplicateItem`.
        try delete(for: kind)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: json,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    public func load(for kind: ProviderInfo.Kind) throws -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
        guard let data = item as? Data else {
            return nil
        }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    public func delete(for kind: ProviderInfo.Kind) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]

        let status = SecItemDelete(query as CFDictionary)
        // Deleting a non-existent item is a no-op success.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}

/// Errors surfaced by `KeychainCredentialStore`.
public enum KeychainError: Error, Equatable {
    /// An unexpected `OSStatus` returned by a Security framework call.
    case unhandled(OSStatus)
}

#endif
