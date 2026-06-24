import Foundation
@testable import ReadrKit

/// Shared test doubles for the M2/M3 suites. Do not redefine these in individual
/// test files — import and use them here.

// MARK: - HTTP

/// Scriptable HTTP transport. Records requests; replies via `sendHandler` and
/// emits `streamChunks` for streaming calls.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    var sendHandler: (@Sendable (HTTPRequest) throws -> HTTPResponse)?
    var streamChunks: [Data] = []
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock(); _requests.append(request); lock.unlock()
        if let handler = sendHandler { return try handler(request) }
        return HTTPResponse(status: 200)
    }

    func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        lock.lock(); _requests.append(request); lock.unlock()
        let chunks = streamChunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

/// Fails (and records) on any network use — enforces the local/offline path (J7).
final class NetworkSentinel: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _attemptedURLs: [URL] = []
    var attemptedURLs: [URL] { lock.lock(); defer { lock.unlock() }; return _attemptedURLs }
    var didAttemptNetwork: Bool { !attemptedURLs.isEmpty }

    private func record(_ url: URL) { lock.lock(); _attemptedURLs.append(url); lock.unlock() }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        record(request.url)
        throw URLError(.notConnectedToInternet)
    }
    func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        record(request.url)
        throw URLError(.notConnectedToInternet)
    }
}

// MARK: - Credentials

/// In-memory `CredentialStore` for tests (the production analog is the real
/// `InMemoryCredentialStore` / `KeychainCredentialStore`).
final class FakeCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProviderInfo.Kind: Credentials] = [:]

    func save(_ credentials: Credentials, for kind: ProviderInfo.Kind) throws {
        lock.lock(); defer { lock.unlock() }; storage[kind] = credentials
    }
    func load(for kind: ProviderInfo.Kind) throws -> Credentials? {
        lock.lock(); defer { lock.unlock() }; return storage[kind]
    }
    func delete(for kind: ProviderInfo.Kind) throws {
        lock.lock(); defer { lock.unlock() }; storage[kind] = nil
    }
}

// MARK: - LLM

/// Scripted `LLMProvider` that streams predefined chunks.
final class MockLLMProvider: LLMProvider, @unchecked Sendable {
    let info: ProviderInfo
    var scriptedChunks: [String]
    private(set) var receivedRequests: [ChatRequest] = []

    init(info: ProviderInfo, scriptedChunks: [String] = ["Hello"]) {
        self.info = info
        self.scriptedChunks = scriptedChunks
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        receivedRequests.append(request)
        let chunks = scriptedChunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(ChatChunk(textDelta: chunk)) }
            continuation.finish()
        }
    }

    func countTokens(_ text: String) throws -> Int { max(1, text.count / 4) }
}

extension ProviderInfo {
    /// Convenience fixture.
    static func fixture(
        kind: Kind = .anthropic,
        modelID: String = "test-model",
        contextBudget: Int = 200_000,
        supportsPromptCaching: Bool = true,
        isLocal: Bool = false
    ) -> ProviderInfo {
        ProviderInfo(
            kind: kind,
            modelID: modelID,
            contextBudget: contextBudget,
            supportsPromptCaching: supportsPromptCaching,
            isLocal: isLocal
        )
    }
}
