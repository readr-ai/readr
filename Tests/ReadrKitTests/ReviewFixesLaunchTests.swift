import XCTest
@testable import ReadrKit

/// Regression tests for the v1 launch-readiness fixes:
///   - A5: URLError → actionable `HTTPError.transport` messages.
///   - A2: API-key validation state in `ProviderManager` + provider test calls.
///   - A3: Ollama readiness probe classification.
final class ReviewFixesLaunchTests: XCTestCase {

    // MARK: - A5: transport (URLError) mapping

    func testTimedOutHasActionableMessage() {
        let error = HTTPError.transport(.timedOut)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.localizedCaseInsensitiveContains("timed out"), message)
        XCTAssertFalse(message.contains("operation couldn't be completed"), message)
        let recovery = error.recoverySuggestion ?? ""
        XCTAssertTrue(recovery.localizedCaseInsensitiveContains("try again"), recovery)
    }

    func testNotConnectedToInternetHasActionableMessage() {
        let error = HTTPError.transport(.notConnectedToInternet)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.localizedCaseInsensitiveContains("offline"), message)
        let recovery = error.recoverySuggestion ?? ""
        XCTAssertTrue(recovery.localizedCaseInsensitiveContains("reconnect"), recovery)
    }

    func testCannotConnectToHostHasActionableMessage() {
        let error = HTTPError.transport(.cannotConnectToHost)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.localizedCaseInsensitiveContains("reach"), message)
        let recovery = error.recoverySuggestion ?? ""
        XCTAssertFalse(recovery.isEmpty, "expected a recovery suggestion")
        XCTAssertFalse(message.contains("operation couldn't be completed"), message)
    }

    func testTransportErrorIsEquatableAndDistinct() {
        // The URLError→HTTPError.transport mapping lives in URLSessionHTTPClient;
        // assert the enum shape it produces stays Equatable and distinguishes
        // codes, so callers/tests can match on it.
        XCTAssertEqual(HTTPError.transport(.timedOut), HTTPError.transport(.timedOut))
        XCTAssertNotEqual(HTTPError.transport(.timedOut), HTTPError.transport(.notConnectedToInternet))
    }

    // MARK: - A2: OpenAI / Anthropic credential validation

    func testOpenAIValidateSucceedsOn200() async throws {
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in HTTPResponse(status: 200) }
        let provider = OpenAIProvider(credentials: .apiKey("sk-test"), http: mock)
        try await provider.validateCredential()
        let recorded = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(recorded.url.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(recorded.method, .get)
        XCTAssertEqual(recorded.headers["authorization"], "Bearer sk-test")
    }

    func testOpenAIValidateThrowsOn401() async {
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in HTTPResponse(status: 401, body: Data("bad key".utf8)) }
        let provider = OpenAIProvider(credentials: .apiKey("sk-bad"), http: mock)
        do {
            try await provider.validateCredential()
            XCTFail("expected 401 to throw")
        } catch let error as HTTPError {
            XCTAssertEqual(error, .status(401, body: "bad key"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAnthropicValidateSucceedsOn200() async throws {
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in HTTPResponse(status: 200) }
        let provider = AnthropicProvider(credentials: .apiKey("sk-ant"), http: mock)
        try await provider.validateCredential()
        let recorded = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(recorded.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(recorded.method, .post)
        XCTAssertEqual(recorded.headers["x-api-key"], "sk-ant")
    }

    func testAnthropicValidateThrowsOn403() async {
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in HTTPResponse(status: 403) }
        let provider = AnthropicProvider(credentials: .apiKey("sk-bad"), http: mock)
        do {
            try await provider.validateCredential()
            XCTFail("expected 403 to throw")
        } catch let error as HTTPError {
            XCTAssertEqual(error, .status(403, body: ""))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - A2: ProviderManager validation state

    /// A factory that builds real providers against a scripted HTTP mock, so we
    /// can drive validate() end-to-end through ProviderManager.
    private func makeManager(
        store: FakeCredentialStore,
        http: HTTPClient
    ) -> ProviderManager {
        ProviderManager(store: store, factory: DefaultProviderFactory.factory(http: http))
    }

    func testValidateStaysUnvalidatedOn401() async throws {
        let store = FakeCredentialStore()
        try store.save(.apiKey("sk-bad"), for: .openAI)
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in HTTPResponse(status: 401) }
        let manager = makeManager(store: store, http: mock)

        // A stored-but-unvalidated remote key is not yet "active".
        let state = await manager.validate(.openAI)
        guard case .invalid = state else {
            return XCTFail("expected .invalid, got \(state)")
        }
        XCTAssertFalse(manager.isValidated(.openAI))
        XCTAssertFalse(manager.isConfigured(.openAI), "401 key must not count as configured")
    }

    func testValidateBecomesActiveOn200() async throws {
        let store = FakeCredentialStore()
        try store.save(.apiKey("sk-good"), for: .openAI)
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in HTTPResponse(status: 200) }
        let manager = makeManager(store: store, http: mock)

        let state = await manager.validate(.openAI)
        XCTAssertEqual(state, .active)
        XCTAssertTrue(manager.isValidated(.openAI))
        XCTAssertTrue(manager.isConfigured(.openAI))
    }

    func testValidateMissingCredentialIsInvalid() async {
        let store = FakeCredentialStore()
        let mock = MockHTTPClient()
        let manager = makeManager(store: store, http: mock)

        let state = await manager.validate(.anthropic)
        guard case .invalid = state else {
            return XCTFail("expected .invalid, got \(state)")
        }
        XCTAssertTrue(mock.requests.isEmpty, "no network call when nothing is stored")
    }

    func testValidationDoesNotBreakSelectionPersistence() {
        let defaults = UserDefaults(suiteName: "readr.test.\(UUID().uuidString)")!
        let store = FakeCredentialStore()
        let manager = ProviderManager(
            store: store,
            factory: DefaultProviderFactory.factory(http: MockHTTPClient()),
            persistingIn: defaults
        )
        manager.setActive(kind: .openAI, modelID: "gpt-4.1-mini")

        // A fresh manager restores the persisted selection.
        let restored = ProviderManager(
            store: store,
            factory: DefaultProviderFactory.factory(http: MockHTTPClient()),
            persistingIn: defaults
        )
        XCTAssertEqual(restored.selection?.kind, .openAI)
        XCTAssertEqual(restored.selection?.modelID, "gpt-4.1-mini")
    }

    // MARK: - activeProvider() honors validation state

    /// Cold launch: a stored key that has never been validated this session
    /// must still resolve, so Ask works at launch / offline before Settings
    /// runs a live check. (Optimistic `nil`-state path.)
    func testActiveProviderResolvesNeverValidatedStoredKey() throws {
        let store = FakeCredentialStore()
        try store.save(.apiKey("sk-unchecked"), for: .openAI)
        let manager = makeManager(store: store, http: MockHTTPClient())
        manager.setActive(kind: .openAI)

        XCTAssertNil(manager.validationState(.openAI), "precondition: never validated")
        XCTAssertNotNil(try manager.activeProvider(), "unchecked stored key must resolve")
    }

    /// After a 401 marks the key `.invalid`, activeProvider() must refuse to
    /// resolve it rather than keep using a credential we know is bad.
    func testActiveProviderRefusesInvalidKeyAfter401() async throws {
        let store = FakeCredentialStore()
        try store.save(.apiKey("sk-bad"), for: .openAI)
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in HTTPResponse(status: 401) }
        let manager = makeManager(store: store, http: mock)
        manager.setActive(kind: .openAI)

        _ = await manager.validate(.openAI)
        guard case .invalid = manager.validationState(.openAI) else {
            return XCTFail("expected .invalid after 401")
        }
        XCTAssertThrowsError(try manager.activeProvider()) { error in
            XCTAssertEqual(error as? ProviderManager.ProviderError, .notConfigured(.openAI))
        }
    }

    /// `clearValidation` reverts to the never-checked state, so a replaced key
    /// stops being gated by the previous key's `.invalid` result.
    func testClearValidationRestoresOptimisticResolution() async throws {
        let store = FakeCredentialStore()
        try store.save(.apiKey("sk-bad"), for: .openAI)
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in HTTPResponse(status: 401) }
        let manager = makeManager(store: store, http: mock)
        manager.setActive(kind: .openAI)

        _ = await manager.validate(.openAI)
        XCTAssertThrowsError(try manager.activeProvider())

        // User pastes a new key: clearing validation restores optimistic resolve.
        try store.save(.apiKey("sk-fresh"), for: .openAI)
        manager.clearValidation(.openAI)
        XCTAssertNil(manager.validationState(.openAI))
        XCTAssertNotNil(try manager.activeProvider(), "cleared key must resolve again")
    }

    // MARK: - A3: Ollama probe classification + ProviderManager .local readiness

    func testProbeReadyWhenModelInstalled() async {
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in
            HTTPResponse(status: 200, body: Data(#"{"models":[{"name":"llama3:latest"},{"name":"qwen2.5"}]}"#.utf8))
        }
        let provider = LocalLLMProvider(model: "llama3", http: mock)
        let result = await provider.probe()
        XCTAssertEqual(result, .ready)
    }

    func testProbeModelMissingWhenTagAbsent() async {
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in
            HTTPResponse(status: 200, body: Data(#"{"models":[{"name":"qwen2.5"}]}"#.utf8))
        }
        let provider = LocalLLMProvider(model: "llama3", http: mock)
        let result = await provider.probe()
        XCTAssertEqual(result, .modelMissing(requested: "llama3", available: ["qwen2.5"]))
    }

    func testProbeNotRunningOnConnectionRefused() async {
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in throw URLError(.cannotConnectToHost) }
        let provider = LocalLLMProvider(model: "llama3", http: mock)
        let result = await provider.probe()
        XCTAssertEqual(result, .notRunning)
    }

    func testProbeHitsTagsEndpoint() async throws {
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in HTTPResponse(status: 200, body: Data(#"{"models":[]}"#.utf8)) }
        let provider = LocalLLMProvider(model: "llama3", http: mock)
        _ = await provider.probe()
        let recorded = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(recorded.url.host, "127.0.0.1")
        XCTAssertEqual(recorded.url.port, 11434)
        XCTAssertEqual(recorded.url.path, "/api/tags")
        XCTAssertEqual(recorded.method, .get)
    }

    func testManagerLocalReadinessReflectsProbe() async {
        let store = FakeCredentialStore()

        // Server up, model present → local becomes active/configured.
        let ready = MockHTTPClient()
        ready.sendHandler = { _ in
            HTTPResponse(status: 200, body: Data(#"{"models":[{"name":"llama3"}]}"#.utf8))
        }
        let readyManager = makeManager(store: store, http: ready)
        let readyState = await readyManager.validate(.local)
        XCTAssertEqual(readyState, .active)
        XCTAssertTrue(readyManager.isConfigured(.local))

        // Server down → transient .unavailable (recovers when Ollama restarts),
        // so it's not "verified ready" but must NOT be condemned as .invalid.
        let down = MockHTTPClient()
        down.sendHandler = { _ in throw URLError(.cannotConnectToHost) }
        let downManager = makeManager(store: store, http: down)
        let state = await downManager.validate(.local)
        guard case .unavailable = state else {
            return XCTFail("expected .unavailable for down server, got \(state)")
        }
        XCTAssertFalse(downManager.isConfigured(.local), "down Ollama must not count as verified-ready")
    }

    // MARK: - Transient failures stay optimistic; in-flight race is guarded

    /// A transient remote failure (offline/timeout, 429, 5xx) must NOT condemn
    /// a stored key: it maps to `.unavailable`, and `activeProvider()` still
    /// resolves so Ask recovers once the network/provider is back.
    func testTransientRemoteFailureDoesNotPoisonActiveProvider() async throws {
        for scripted: @Sendable (HTTPRequest) throws -> HTTPResponse in [
            { _ in throw URLError(.timedOut) },
            { _ in HTTPResponse(status: 429) },
            { _ in HTTPResponse(status: 503) },
        ] {
            let store = FakeCredentialStore()
            try store.save(.apiKey("sk-maybe-good"), for: .openAI)
            let mock = MockHTTPClient()
            mock.sendHandler = scripted
            let manager = makeManager(store: store, http: mock)
            manager.setActive(kind: .openAI)

            let state = await manager.validate(.openAI)
            guard case .unavailable = state else {
                return XCTFail("expected .unavailable for transient failure, got \(state)")
            }
            XCTAssertNotNil(
                try manager.activeProvider(),
                "a transient failure must leave the stored key optimistically usable"
            )
        }
    }

    /// A 401 during validation is a genuine rejection → `.invalid`, which DOES
    /// block `activeProvider()` (contrast with the transient case above).
    func testAuthRejectionPoisonsButTransientDoesNot() async throws {
        let store = FakeCredentialStore()
        try store.save(.apiKey("sk-bad"), for: .openAI)
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in HTTPResponse(status: 401) }
        let manager = makeManager(store: store, http: mock)
        manager.setActive(kind: .openAI)

        let state = await manager.validate(.openAI)
        guard case .invalid = state else {
            return XCTFail("expected .invalid for 401, got \(state)")
        }
        XCTAssertThrowsError(try manager.activeProvider())
    }

    /// A stale in-flight `validate` that finishes after `clearValidation` (the
    /// user replaced the key) must not overwrite the fresh never-checked state.
    func testStaleValidationDoesNotOverwriteAfterClear() async throws {
        let store = FakeCredentialStore()
        try store.save(.apiKey("sk-old-bad"), for: .openAI)

        // Gate the validate() network call so we can interleave a clearValidation
        // between its .validating entry and its result commit.
        let release = XCTestExpectation(description: "release scripted response")
        let entered = XCTestExpectation(description: "handler entered")
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in
            entered.fulfill()
            XCTWaiter().wait(for: [release], timeout: 5)
            return HTTPResponse(status: 401) // old key was bad
        }
        let manager = makeManager(store: store, http: mock)
        manager.setActive(kind: .openAI)

        async let stale = manager.validate(.openAI)
        await fulfillment(of: [entered], timeout: 2)

        // User replaces the key mid-flight; clearing bumps the generation.
        try store.save(.apiKey("sk-new-good"), for: .openAI)
        manager.clearValidation(.openAI)

        release.fulfill()
        _ = await stale

        // The stale 401 result must have been discarded, leaving the fresh
        // never-checked state — so activeProvider() still resolves the new key.
        XCTAssertNil(manager.validationState(.openAI), "stale result must not land")
        XCTAssertNotNil(try manager.activeProvider())
    }

    /// A model change (setActive) while a validation is in flight must not leave
    /// the kind stuck in `.validating`: setActive bumps the generation AND
    /// clears the cached state, so the discarded stale check doesn't freeze the
    /// card on "Validating…" / drop it out of isConfigured.
    func testModelChangeMidValidationDoesNotStickValidating() async throws {
        let store = FakeCredentialStore()
        try store.save(.apiKey("sk-good"), for: .openAI)

        let release = XCTestExpectation(description: "release scripted response")
        let entered = XCTestExpectation(description: "handler entered")
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in
            entered.fulfill()
            XCTWaiter().wait(for: [release], timeout: 5)
            return HTTPResponse(status: 200)
        }
        let manager = makeManager(store: store, http: mock)
        manager.setActive(kind: .openAI, modelID: "gpt-4.1-mini")

        async let stale = manager.validate(.openAI)
        await fulfillment(of: [entered], timeout: 2)

        // User switches model mid-flight — invalidates the in-flight check.
        manager.setActive(kind: .openAI, modelID: "gpt-4.1")

        release.fulfill()
        _ = await stale

        // State must NOT be stuck at .validating; it reverts to never-checked.
        XCTAssertNil(manager.validationState(.openAI), "must not stick at .validating")
        XCTAssertNotNil(try manager.activeProvider(), "provider still optimistically usable")
    }
}
