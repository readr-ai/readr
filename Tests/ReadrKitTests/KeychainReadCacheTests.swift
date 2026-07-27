import XCTest
@testable import ReadrKit

/// `KeychainReadCache` exists to collapse repeated Keychain reads.
///
/// The motivating bug is macOS-specific and user-visible: when the app's code
/// signature differs from the one that wrote a Keychain item, EVERY
/// `SecItemCopyMatching` raises a "Readr wants to use your confidential
/// information" ACL prompt, and clicking Allow authorizes only that single
/// read. Opening the providers sheet performed three or more loads per kind,
/// so the user got a storm of identical dialogs. One read per kind means one
/// dialog.
final class KeychainReadCacheTests: XCTestCase {
    /// Counts reads so tests can assert the backing store is consulted once.
    private final class CountingStore: CredentialStore, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ProviderInfo.Kind: Credentials] = [:]
        private var _loadCount: [ProviderInfo.Kind: Int] = [:]
        /// When set, `load` throws instead of returning.
        var loadError: Error?

        var loadCount: [ProviderInfo.Kind: Int] {
            lock.lock(); defer { lock.unlock() }; return _loadCount
        }

        func save(_ credentials: Credentials, for kind: ProviderInfo.Kind) throws {
            lock.lock(); defer { lock.unlock() }; storage[kind] = credentials
        }

        func load(for kind: ProviderInfo.Kind) throws -> Credentials? {
            lock.lock()
            _loadCount[kind, default: 0] += 1
            let error = loadError
            let value = storage[kind]
            lock.unlock()
            if let error { throw error }
            return value
        }

        func delete(for kind: ProviderInfo.Kind) throws {
            lock.lock(); defer { lock.unlock() }; storage[kind] = nil
        }
    }

    private struct Boom: Error {}

    // MARK: - Read collapsing

    func testRepeatedLoadsHitTheBackingStoreOnce() throws {
        let backing = CountingStore()
        try backing.save(.apiKey("sk-test"), for: .openAI)
        let store = KeychainReadCache(wrapping: backing)

        for _ in 0..<5 {
            XCTAssertEqual(try store.load(for: .openAI), .apiKey("sk-test"))
        }

        XCTAssertEqual(
            backing.loadCount[.openAI], 1,
            "Five loads of the same kind must produce exactly one Keychain read"
        )
    }

    /// The absent case matters as much as the present one: `hasStoredCredential`
    /// is called for every kind on every settings refresh, and most kinds have
    /// nothing stored.
    func testAbsentCredentialIsCachedToo() throws {
        let backing = CountingStore()
        let store = KeychainReadCache(wrapping: backing)

        for _ in 0..<4 {
            XCTAssertNil(try store.load(for: .anthropic))
        }

        XCTAssertEqual(
            backing.loadCount[.anthropic], 1,
            "A miss must be cached — re-probing an absent kind still prompts on macOS"
        )
    }

    func testKindsAreCachedIndependently() throws {
        let backing = CountingStore()
        try backing.save(.apiKey("a"), for: .openAI)
        try backing.save(.apiKey("b"), for: .openRouter)
        let store = KeychainReadCache(wrapping: backing)

        XCTAssertEqual(try store.load(for: .openAI), .apiKey("a"))
        XCTAssertEqual(try store.load(for: .openRouter), .apiKey("b"))
        XCTAssertEqual(try store.load(for: .openAI), .apiKey("a"))

        XCTAssertEqual(backing.loadCount[.openAI], 1)
        XCTAssertEqual(backing.loadCount[.openRouter], 1)
    }

    // MARK: - Invalidation

    /// SettingsModel writes credentials straight to the store, so a write must
    /// be visible to the very next read without a Keychain round trip.
    func testSaveIsVisibleImmediatelyWithoutRereading() throws {
        let backing = CountingStore()
        let store = KeychainReadCache(wrapping: backing)

        _ = try store.load(for: .openAI) // prime the miss
        try store.save(.apiKey("fresh"), for: .openAI)

        XCTAssertEqual(try store.load(for: .openAI), .apiKey("fresh"))
        XCTAssertEqual(
            backing.loadCount[.openAI], 1,
            "A write-through save must update the cache rather than invalidate it"
        )
    }

    func testDeleteIsVisibleImmediately() throws {
        let backing = CountingStore()
        try backing.save(.apiKey("sk-test"), for: .openAI)
        let store = KeychainReadCache(wrapping: backing)

        XCTAssertEqual(try store.load(for: .openAI), .apiKey("sk-test"))
        try store.delete(for: .openAI)

        XCTAssertNil(try store.load(for: .openAI), "Disconnect must take effect at once")
    }

    /// Rotated OAuth tokens are saved through the same seam; a stale cache
    /// would hand an expired access token back to the provider.
    func testResavingReplacesTheCachedValue() throws {
        let backing = CountingStore()
        let store = KeychainReadCache(wrapping: backing)

        try store.save(.apiKey("first"), for: .chatGPT)
        try store.save(.apiKey("second"), for: .chatGPT)

        XCTAssertEqual(try store.load(for: .chatGPT), .apiKey("second"))
    }

    // MARK: - Failure handling

    /// A transient Keychain failure (locked keychain, user clicked Deny) must
    /// not be cached as "no credential" — that would strand the account until
    /// relaunch.
    func testLoadFailureIsNotCached() throws {
        let backing = CountingStore()
        try backing.save(.apiKey("sk-test"), for: .openAI)
        let store = KeychainReadCache(wrapping: backing)

        backing.loadError = Boom()
        XCTAssertThrowsError(try store.load(for: .openAI))

        backing.loadError = nil
        XCTAssertEqual(
            try store.load(for: .openAI), .apiKey("sk-test"),
            "A failed read must be retried, not remembered as absent"
        )
    }

    /// A failed write must not leave the cache claiming the credential landed.
    func testSaveFailureDoesNotPopulateTheCache() throws {
        struct FailingStore: CredentialStore, @unchecked Sendable {
            func save(_ credentials: Credentials, for kind: ProviderInfo.Kind) throws {
                throw Boom()
            }
            func load(for kind: ProviderInfo.Kind) throws -> Credentials? { nil }
            func delete(for kind: ProviderInfo.Kind) throws {}
        }
        let store = KeychainReadCache(wrapping: FailingStore())

        XCTAssertThrowsError(try store.save(.apiKey("x"), for: .openAI))
        XCTAssertNil(try store.load(for: .openAI), "A failed save must not populate the cache")
    }
}
