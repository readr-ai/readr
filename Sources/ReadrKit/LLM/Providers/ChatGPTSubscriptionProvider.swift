import Foundation

/// "Sign in with ChatGPT" provider: streams from ChatGPT's backend Responses
/// endpoint using the OAuth tokens obtained via the Codex public client.
///
/// This is deliberately NOT `OpenAIProvider` with different endpoints — the
/// wire format differs on every axis: Responses-API request body, an extra
/// `ChatGPT-Account-Id` header derived from the access token's JWT claims,
/// and Responses-style SSE events instead of Chat Completions deltas. The
/// request/stream shapes mirror working third-party implementations (Muesli);
/// the backend is unofficial, so shapes carry NEEDS-VERIFICATION notes and
/// the first live sign-in must confirm them (docs/AUTH.md).
public struct ChatGPTSubscriptionProvider: LLMProvider, CredentialValidating {

    /// Reader-facing failures specific to this transport.
    public enum BackendError: Error, LocalizedError, Equatable {
        /// The access token carries no ChatGPT account id — nothing this
        /// transport can do until the user signs in again.
        case missingAccountID
        /// The backend reported a failed response mid-stream.
        case responseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingAccountID:
                return "Your ChatGPT session can't be used anymore. Sign in with ChatGPT again in Settings → AI Providers."
            case .responseFailed(let message):
                return "ChatGPT couldn't finish the reply: \(message)"
            }
        }
    }

    public let info: ProviderInfo

    private let credentials: Credentials
    private let model: String
    private let http: HTTPClient

    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/responses")!
    /// Cheapest authenticated probe of the backend. NEEDS-VERIFICATION: path
    /// unconfirmed; a wrong guess degrades to `.unavailable` (optimistic), not
    /// `.invalid`, because only 401/403 condemn a credential.
    static let validationEndpoint = URL(string: "https://chatgpt.com/backend-api/models")!

    public init(
        credentials: Credentials,
        model: String = "gpt-5.4-mini",
        http: HTTPClient = URLSessionHTTPClient(),
        contextBudget: Int = 128_000
    ) {
        self.credentials = credentials
        self.model = model
        self.http = http
        self.info = ProviderInfo(
            kind: .chatGPT,
            modelID: model,
            contextBudget: contextBudget,
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
                            if let message = Self.failureMessage(fromEventPayload: payload) {
                                throw BackendError.responseFailed(message)
                            }
                            if Self.isCompletionEvent(payload) {
                                continuation.finish()
                                return
                            }
                            if let delta = Self.textDelta(fromEventPayload: payload) {
                                continuation.yield(ChatChunk(textDelta: delta))
                            }
                        }
                    }
                    // The backend may end the stream without a [DONE] sentinel.
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

    /// Two layers: a local check that the token even carries a ChatGPT account
    /// id (a synthetic 401 — proven unusable, no network needed), then an
    /// authenticated probe of the backend.
    public func validateCredential() async throws {
        guard case let .oauth(accessToken, _, _) = credentials,
              let accountID = Self.chatGPTAccountID(fromAccessToken: accessToken) else {
            throw HTTPError.status(401, body: "access token carries no ChatGPT account")
        }
        let response = try await http.send(
            HTTPRequest(
                url: Self.validationEndpoint,
                method: .get,
                headers: headers(accessToken: authTokenOrEmpty, accountID: accountID)
            )
        )
        try response.throwIfUnsuccessful()
    }

    // MARK: - JWT claims

    /// Extract the ChatGPT account id from the access token's (unverified)
    /// JWT payload: `chatgpt_account_id` at the top level, else nested under
    /// the `https://api.openai.com/auth` claim.
    public static func chatGPTAccountID(fromAccessToken token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count == 3, let payload = base64URLDecode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        if let id = object["chatgpt_account_id"] as? String, !id.isEmpty {
            return id
        }
        if let auth = object["https://api.openai.com/auth"] as? [String: Any],
           let id = auth["chatgpt_account_id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private static func base64URLDecode(_ segment: String) -> Data? {
        var base64 = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    // MARK: - Request building

    private var authTokenOrEmpty: String {
        if case let .oauth(accessToken, _, _) = credentials { return accessToken }
        return ""
    }

    private func headers(accessToken: String, accountID: String) -> [String: String] {
        [
            "authorization": "Bearer \(accessToken)",
            "content-type": "application/json",
            "ChatGPT-Account-Id": accountID,
        ]
    }

    private func makeRequest(_ request: ChatRequest) throws -> HTTPRequest {
        guard case let .oauth(accessToken, _, _) = credentials,
              let accountID = Self.chatGPTAccountID(fromAccessToken: accessToken) else {
            throw BackendError.missingAccountID
        }
        return HTTPRequest(
            url: Self.endpoint,
            method: .post,
            headers: headers(accessToken: accessToken, accountID: accountID),
            body: try Self.encodeBody(request, model: model)
        )
    }

    /// Responses-API request body. System content (the cacheable prefix plus
    /// any `.system` messages) folds into `instructions`; the remaining turns
    /// become `input` items. `ChatRequest.maxOutputTokens` is intentionally
    /// not sent — the verified working body omits it, and the backend's
    /// support for a cap is unconfirmed.
    static func encodeBody(_ request: ChatRequest, model: String) throws -> Data {
        var payload: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
        ]

        let systemParts = [request.cacheableSystemPrefix].compactMap { $0 }
            + request.messages.filter { $0.role == .system }.map(\.content)
        if !systemParts.isEmpty {
            payload["instructions"] = systemParts.joined(separator: "\n\n")
        }

        payload["input"] = request.messages
            .filter { $0.role != .system }
            .map { message -> [String: Any] in
                // NEEDS-VERIFICATION: assistant history items use output_text
                // per the Responses API; the verified body only ever sent user
                // turns.
                let contentType = message.role == .assistant ? "output_text" : "input_text"
                return [
                    "role": message.role.rawValue,
                    "content": [["type": contentType, "text": message.content]],
                ]
            }

        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    // MARK: - Response parsing

    /// The text delta from a Responses-API stream event, or nil for every
    /// other event type.
    static func textDelta(fromEventPayload json: String) -> String? {
        guard let object = parse(json),
              object["type"] as? String == "response.output_text.delta",
              let delta = object["delta"] as? String, !delta.isEmpty else {
            return nil
        }
        return delta
    }

    /// A human-readable message when the event reports failure, else nil.
    static func failureMessage(fromEventPayload json: String) -> String? {
        guard let object = parse(json) else { return nil }
        let type = object["type"] as? String
        guard type == "response.failed" || type == "error" else { return nil }
        let error = ((object["response"] as? [String: Any])?["error"] ?? object["error"])
            as? [String: Any]
        return (error?["message"] as? String) ?? "the response failed"
    }

    static func isCompletionEvent(_ json: String) -> Bool {
        parse(json)?["type"] as? String == "response.completed"
    }

    private static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
