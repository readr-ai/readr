import Foundation

/// OpenAI Chat Completions provider with SSE streaming.
///
/// The wire format is shared by several hosts, so the endpoints are a
/// parameter: `.openAI` (the default) talks to api.openai.com, `.openRouter`
/// to openrouter.ai. Rule of thumb: a host that speaks byte-identical Chat
/// Completions becomes an `Endpoints` preset here; a different wire format
/// gets its own provider struct (see `ChatGPTSubscriptionProvider`).
public struct OpenAIProvider: LLMProvider, CredentialValidating {

    /// Where an OpenAI-wire-compatible host lives: its chat endpoint, the
    /// cheapest authenticated URL for key validation, and the `Kind` it
    /// reports so routing and persistence stay per-host.
    public struct Endpoints: Sendable, Equatable {
        public let kind: ProviderInfo.Kind
        public let chatURL: URL
        public let validationURL: URL
        /// Extra static headers sent on every request (none for OpenAI;
        /// OpenRouter recognizes optional attribution headers).
        public let extraHeaders: [String: String]

        public static let openAI = Endpoints(
            kind: .openAI,
            chatURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
            validationURL: URL(string: "https://api.openai.com/v1/models")!,
            extraHeaders: [:]
        )

        public static let openRouter = Endpoints(
            kind: .openRouter,
            chatURL: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            // GET /api/v1/key describes the presented key — the cheapest
            // authenticated call; 401 on a revoked/invalid key.
            validationURL: URL(string: "https://openrouter.ai/api/v1/key")!,
            extraHeaders: [:]
        )
    }

    public let info: ProviderInfo

    private let credentials: Credentials
    private let model: String
    private let http: HTTPClient
    private let endpoints: Endpoints

    public init(
        credentials: Credentials,
        model: String = "gpt-4.1",
        http: HTTPClient = URLSessionHTTPClient(),
        contextBudget: Int = 128_000,
        endpoints: Endpoints = .openAI
    ) {
        self.credentials = credentials
        self.model = model
        self.http = http
        self.endpoints = endpoints
        self.info = ProviderInfo(
            kind: endpoints.kind,
            modelID: model,
            contextBudget: contextBudget,
            // OpenAI caches automatically; report false to keep the router conservative.
            supportsPromptCaching: false,
            isLocal: false
        )
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let httpRequest = try makeRequest(request)
                    let lines = try await http.stream(httpRequest)
                    for try await line in lines {
                        guard let event = SSEParser.parseLine(line) else { continue }
                        switch event {
                        case .done:
                            continuation.finish()
                            return
                        case let .data(payload):
                            if let delta = Self.contentDelta(from: payload) {
                                continuation.yield(ChatChunk(textDelta: delta))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func countTokens(_ text: String) throws -> Int {
        TokenCounter.estimate(text)
    }

    // MARK: - Validation

    /// Cheapest possible credential check: an authenticated GET against the
    /// host's validation URL (`/v1/models` for OpenAI, `/api/v1/key` for
    /// OpenRouter). Returns normally when the key is accepted (HTTP 200);
    /// throws `HTTPError.status(401/403, …)` when the provider rejects the
    /// key, or the underlying transport error for network failures. Reuses the
    /// injected `HTTPClient`, so it is fully mockable in tests.
    public func validateCredential() async throws {
        var headers = endpoints.extraHeaders
        headers["authorization"] = "Bearer \(authToken)"
        let response = try await http.send(
            HTTPRequest(url: endpoints.validationURL, method: .get, headers: headers)
        )
        try response.throwIfUnsuccessful()
    }

    // MARK: - Request building

    private var authToken: String {
        switch credentials {
        case let .apiKey(key): return key
        case let .oauth(accessToken, _, _): return accessToken
        }
    }

    private func makeRequest(_ request: ChatRequest) throws -> HTTPRequest {
        var headers = endpoints.extraHeaders
        headers["authorization"] = "Bearer \(authToken)"
        headers["content-type"] = "application/json"
        let body = try Self.encodeBody(request, model: model)
        return HTTPRequest(url: endpoints.chatURL, method: .post, headers: headers, body: body)
    }

    static func encodeBody(_ request: ChatRequest, model: String) throws -> Data {
        var messages: [[String: Any]] = []
        // A cacheable prefix maps to a leading system message for OpenAI.
        if let prefix = request.cacheableSystemPrefix {
            messages.append(["role": "system", "content": prefix])
        }
        for message in request.messages {
            messages.append(["role": message.role.rawValue, "content": message.content])
        }
        let payload: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages,
            "max_tokens": request.maxOutputTokens,
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    // MARK: - Response parsing

    /// Extract `choices[0].delta.content` from a streamed chunk payload.
    static func contentDelta(from json: String) -> String? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let first = choices.first,
            let delta = first["delta"] as? [String: Any],
            let content = delta["content"] as? String
        else { return nil }
        return content
    }
}
