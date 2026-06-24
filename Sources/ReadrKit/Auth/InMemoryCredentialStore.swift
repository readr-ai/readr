import Foundation

/// A non-persistent `CredentialStore` backed by a thread-safe in-memory dictionary.
///
/// This is the production bootstrap store (used before a real Keychain-backed
/// store is wired up) and the SwiftUI preview / unit-test store. Credentials are
/// held only for the lifetime of the process and are never written to disk.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProviderInfo.Kind: Credentials] = [:]

    public init() {}

    public func save(_ credentials: Credentials, for kind: ProviderInfo.Kind) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[kind] = credentials
    }

    public func load(for kind: ProviderInfo.Kind) throws -> Credentials? {
        lock.lock()
        defer { lock.unlock() }
        return storage[kind]
    }

    public func delete(for kind: ProviderInfo.Kind) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[kind] = nil
    }
}
