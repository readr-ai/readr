import XCTest
@testable import ReadrKit

/// Proactive OAuth refresh: `refreshCredentialsIfNeeded` renews expired
/// tokens through the injected refresher before providers are built.
final class ProviderManagerRefreshTests: XCTestCase {

    /// A `CredentialValidating` provider whose probe blocks until released,
    /// so tests can interleave other manager calls mid-validation.
    private final class GatedValidatingProvider: LLMProvider, CredentialValidating, @unchecked Sendable {
        let info = ProviderInfo(
            kind: .chatGPT, modelID: "gpt-5.4-mini", contextBudget: 128_000,
            supportsPromptCaching: false, isLocal: false
        )
        private let started = AsyncStream<Void>.makeStream()
        private let release = AsyncStream<Void>.makeStream()

        /// Await the probe having begun.
        func probeStarted() async { for await _ in started.stream { break } }
        func releaseProbe() { release.continuation.yield() }

        func validateCredential() async throws {
            started.continuation.yield()
            for await _ in release.stream { break }
        }

        func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func countTokens(_ text: String) throws -> Int { max(1, text.count / 4) }
    }

    /// Thread-safe call recorder for the refresher closure.
    private final class RefreshRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func record() { lock.lock(); _calls += 1; lock.unlock() }
    }

    private func expiredCredentials() -> Credentials {
        .oauth(accessToken: "old-at", refreshToken: "rt", expiresAt: Date(timeIntervalSinceNow: -60))
    }

    private func makeManager(
        store: FakeCredentialStore,
        refresher: ProviderManager.TokenRefresher?
    ) -> ProviderManager {
        ProviderManager(
            store: store,
            factory: { info, _ in MockLLMProvider(info: info) },
            tokenRefresher: refresher
        )
    }

    func testExpiredOAuthTriggersRefresherOnceAndPersists() async throws {
        let store = FakeCredentialStore()
        try store.save(expiredCredentials(), for: .chatGPT)
        let recorder = RefreshRecorder()
        let manager = makeManager(store: store) { kind, credentials in
            recorder.record()
            XCTAssertEqual(kind, .chatGPT)
            guard case .oauth(_, "rt", _) = credentials else {
                XCTFail("refresher should receive the stored credentials")
                throw AuthError.refreshFailed
            }
            return .oauth(accessToken: "new-at", refreshToken: "rt2", expiresAt: Date(timeIntervalSinceNow: 3600))
        }

        await manager.refreshCredentialsIfNeeded(.chatGPT)

        XCTAssertEqual(recorder.calls, 1)
        guard case let .oauth(accessToken, refreshToken, _)? = try store.load(for: .chatGPT) else {
            return XCTFail("expected refreshed oauth credentials in the store")
        }
        XCTAssertEqual(accessToken, "new-at")
        XCTAssertEqual(refreshToken, "rt2")
        // A successful refresh is the same logical credential — no state reset.
        XCTAssertNil(manager.validationState(.chatGPT))
    }

    func testTokenExpiringWithinSkewWindowIsRefreshed() async throws {
        let store = FakeCredentialStore()
        // Not yet expired, but within the 60s early-refresh skew.
        try store.save(
            .oauth(accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSinceNow: 30)),
            for: .chatGPT
        )
        let recorder = RefreshRecorder()
        let manager = makeManager(store: store) { _, _ in
            recorder.record()
            return .oauth(accessToken: "new", refreshToken: "rt", expiresAt: Date(timeIntervalSinceNow: 3600))
        }
        await manager.refreshCredentialsIfNeeded(.chatGPT)
        XCTAssertEqual(recorder.calls, 1)
    }

    func testFreshTokenAndAPIKeyAreNotRefreshed() async throws {
        let store = FakeCredentialStore()
        try store.save(
            .oauth(accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSinceNow: 3600)),
            for: .chatGPT
        )
        try store.save(.apiKey("sk-or"), for: .openRouter)
        let recorder = RefreshRecorder()
        let manager = makeManager(store: store) { _, _ in
            recorder.record()
            throw AuthError.refreshFailed
        }

        await manager.refreshCredentialsIfNeeded(.chatGPT)
        await manager.refreshCredentialsIfNeeded(.openRouter)
        // Nothing stored at all is also a no-op.
        await manager.refreshCredentialsIfNeeded(.anthropic)

        XCTAssertEqual(recorder.calls, 0)
    }

    func testWithoutRefresherIsNoOp() async throws {
        let store = FakeCredentialStore()
        let original = expiredCredentials()
        try store.save(original, for: .chatGPT)
        let manager = makeManager(store: store, refresher: nil)
        await manager.refreshCredentialsIfNeeded(.chatGPT)
        // Credentials untouched; no crash, no state change.
        XCTAssertEqual(try store.load(for: .chatGPT), original)
        XCTAssertNil(manager.validationState(.chatGPT))
    }

    func testConcurrentCallsShareOneRefresh() async throws {
        let store = FakeCredentialStore()
        try store.save(expiredCredentials(), for: .chatGPT)
        let recorder = RefreshRecorder()
        let manager = makeManager(store: store) { _, _ in
            recorder.record()
            // Give concurrent callers time to pile onto the in-flight task.
            try await Task.sleep(nanoseconds: 50_000_000)
            return .oauth(accessToken: "new", refreshToken: "rt", expiresAt: Date(timeIntervalSinceNow: 3600))
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await manager.refreshCredentialsIfNeeded(.chatGPT) }
            }
        }

        XCTAssertEqual(recorder.calls, 1)
    }

    func testRejectionMarksInvalidAndKeepsCredentials() async throws {
        let store = FakeCredentialStore()
        try store.save(expiredCredentials(), for: .chatGPT)
        let manager = makeManager(store: store) { _, _ in
            throw AuthError.tokenExchangeFailed("invalid_grant")
        }

        await manager.refreshCredentialsIfNeeded(.chatGPT)

        guard case .invalid(let reason)? = manager.validationState(.chatGPT) else {
            return XCTFail("expected .invalid, got \(String(describing: manager.validationState(.chatGPT)))")
        }
        XCTAssertTrue(
            reason?.localizedCaseInsensitiveContains("sign in") == true,
            reason ?? "nil"
        )
        // The stored credential stays — disconnecting is the user's call.
        XCTAssertNotNil(try store.load(for: .chatGPT))
    }

    func testTransportErrorLeavesStateAndCredentialsUntouched() async throws {
        let store = FakeCredentialStore()
        try store.save(expiredCredentials(), for: .chatGPT)
        let manager = makeManager(store: store) { _, _ in
            throw HTTPError.transport(.notConnectedToInternet)
        }

        await manager.refreshCredentialsIfNeeded(.chatGPT)

        XCTAssertNil(manager.validationState(.chatGPT))
        guard case let .oauth(accessToken, _, _)? = try store.load(for: .chatGPT) else {
            return XCTFail("credentials should be untouched")
        }
        XCTAssertEqual(accessToken, "old-at")
    }

    /// A validate() that was already probing when a refresh rejection lands
    /// must not overwrite the `.invalid` verdict with its stale `.active` —
    /// the old access token may still probe fine right up until expiry.
    func testRefreshRejectionDiscardsInFlightValidation() async throws {
        let store = FakeCredentialStore()
        // Fresh enough to skip refresh at validate() entry (beyond the skew).
        try store.save(
            .oauth(accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSinceNow: 300)),
            for: .chatGPT
        )
        let gate = GatedValidatingProvider()
        let manager = ProviderManager(
            store: store,
            factory: { _, _ in gate },
            tokenRefresher: { _, _ in throw AuthError.tokenExchangeFailed("invalid_grant") }
        )

        let validation = Task { await manager.validate(.chatGPT) }
        await gate.probeStarted()

        // Mid-probe, the token hits expiry elsewhere and the refresh is
        // rejected (e.g. the Ask path tried to renew).
        try store.save(expiredCredentials(), for: .chatGPT)
        await manager.refreshCredentialsIfNeeded(.chatGPT)
        gate.releaseProbe()
        _ = await validation.value

        XCTAssertEqual(
            manager.validationState(.chatGPT),
            .invalid(reason: "Your session has expired. Sign in again in Settings → AI Providers."),
            "the rejection verdict must survive the in-flight validation"
        )
    }

    func testValidateRefreshesExpiredCredentialsFirst() async throws {
        let store = FakeCredentialStore()
        try store.save(expiredCredentials(), for: .chatGPT)
        let recorder = RefreshRecorder()
        let manager = makeManager(store: store) { _, _ in
            recorder.record()
            return .oauth(accessToken: "fresh-at", refreshToken: "rt", expiresAt: Date(timeIntervalSinceNow: 3600))
        }

        _ = await manager.validate(.chatGPT)

        XCTAssertEqual(recorder.calls, 1)
        guard case let .oauth(accessToken, _, _)? = try store.load(for: .chatGPT) else {
            return XCTFail("expected refreshed credentials")
        }
        XCTAssertEqual(accessToken, "fresh-at")
    }
}
