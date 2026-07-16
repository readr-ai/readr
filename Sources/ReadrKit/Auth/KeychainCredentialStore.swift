#if canImport(Security)
import Foundation
import Security

/// A `CredentialStore` that persists secrets in the system Keychain.
///
/// This is the **only** place provider secrets are persisted. Items are stored as
/// `kSecClassGenericPassword` entries protected with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so they are readable only while
/// the device is unlocked, remain encrypted at rest, and — because of the
/// `ThisDeviceOnly` protection class — are **never** included in device backups
/// (iTunes/Finder or iCloud) and are **not** eligible for Keychain iCloud sync.
/// This keeps keys pinned to the device they were entered on, matching the product
/// promise that keys stay on this device.
///
/// Secrets must NEVER be written to `UserDefaults`, plists, app-group containers,
/// log output, or any other location — only here.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    /// The `kSecAttrAccessible` protection class applied to every item this store
    /// writes. Exposed for testability so the non-syncable, device-only guarantee
    /// can be asserted without a live Keychain.
    static var accessibility: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }

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
            kSecAttrAccessible as String: Self.accessibility,
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
