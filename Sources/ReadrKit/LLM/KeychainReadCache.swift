import Foundation

/// A `CredentialStore` decorator that serves each kind's secret from memory
/// after reading it once.
///
/// **Why this exists.** On macOS the legacy Keychain enforces a per-item ACL
/// listing which binaries may read it. When the app's code signature differs
/// from the one that wrote an item — a rebuild under a different identity, or
/// a Developer ID build reading items an ad-hoc build created — every single
/// `SecItemCopyMatching` raises a "Readr wants to use your confidential
/// information" dialog, and **Allow** authorizes only that one read. The
/// settings surface loads each kind's credential three or more times per
/// refresh (`hasStoredCredential`, then `refreshCredentialsIfNeeded`, then
/// `hasStoredCredential` again), so a single visit to the providers sheet
/// produced a storm of identical prompts. Collapsing those to one read per
/// kind collapses the storm to one dialog.
///
/// It is also simply less work: the Keychain is a cross-process call, and the
/// values are already held in memory by the live provider objects, so caching
/// them here widens no exposure that the app did not already have.
///
/// **Consistency.** Writes go through the same object (the composition root
/// hands the *same* instance to both `ProviderManager` and the settings
/// layer), so `save`/`delete` keep the cache authoritative — there is no
/// write path that can leave it stale. Failed reads and failed writes are
/// never cached, so a locked keychain or a **Deny** click is retried rather
/// than remembered as "no credential".
///
/// The one thing it deliberately does not model is another *process* mutating
/// the same Keychain items concurrently; that value would be served stale
/// until relaunch. Readr owns these items exclusively, so that trade is safe.
///
/// Two concurrent first reads of the SAME kind can both miss and both hit the
/// Keychain — the lock is released across the backing call on purpose, since
/// holding it would stall every other kind behind a modal ACL dialog. In
/// practice the settings refresh loads each kind once, so the duplicate is a
/// theoretical extra prompt rather than an observed one; collapsing it would
/// need per-kind in-flight tasks, which is not worth the machinery here.
///
/// Named for its job rather than its shape — collapsing Keychain reads is the
/// entire reason it exists.
public final class KeychainReadCache: CredentialStore, @unchecked Sendable {
    private let backing: any CredentialStore
    private let lock = NSLock()
    /// Kind → cached result. The outer optional is cache membership; the inner
    /// one is the credential itself, so a *known absent* credential is cached
    /// as `.some(nil)` and never re-probed.
    private var cache: [ProviderInfo.Kind: Credentials?] = [:]

    public init(wrapping backing: any CredentialStore) {
        self.backing = backing
    }

    public func save(_ credentials: Credentials, for kind: ProviderInfo.Kind) throws {
        // Write through first: if the Keychain rejects the write, the cache
        // must not claim the credential landed.
        try backing.save(credentials, for: kind)
        lock.lock(); defer { lock.unlock() }
        cache[kind] = .some(credentials)
    }

    public func load(for kind: ProviderInfo.Kind) throws -> Credentials? {
        lock.lock()
        if let cached = cache[kind] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Read outside the lock: the Keychain call can block on a user-facing
        // ACL dialog, and holding the lock across it would stall every other
        // kind behind that prompt.
        let loaded = try backing.load(for: kind)

        lock.lock(); defer { lock.unlock() }
        cache[kind] = .some(loaded)
        return loaded
    }

    public func delete(for kind: ProviderInfo.Kind) throws {
        try backing.delete(for: kind)
        lock.lock(); defer { lock.unlock() }
        cache[kind] = .some(nil)
    }
}
