import Foundation

/// Anthropic Messages API provider with streaming + prompt caching.
public struct AnthropicProvider: LLMProvider {
    public let info: ProviderInfo

    private let credentials: Credentials
    private let model: String
    private let http: HTTPClient

    // NEEDS-VERIFICATION: endpoint path is stable but confirm against current API docs.
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    // NEEDS-VERIFICATION: confirm the current anthropic-version date for the deployed API.
    private static let apiVersion = "2023-06-01"

    public init(
        credentials: Credentials,
        model: String = "claude-opus-4-8",
        http: HTTPClient = URLSessionHTTPClient(),
        contextBudget: Int = 200_000
    ) {
        self.credentials = credentials
        self.model = model
        self.http = http
        self.info = ProviderInfo(
            kind: .anthropic,
            modelID: model,
            contextBudget: contextBudget,
            supportsPromptCaching: true,
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
                            if let delta = Self.textDelta(from: payload) {
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

    // MARK: - Request building

    private func makeRequest(_ request: ChatRequest) throws -> HTTPRequest {
        var headers: [String: String] = [
            "anthropic-version": Self.apiVersion,
            "content-type": "application/json",
        ]
        switch credentials {
        case let .apiKey(key):
            headers["x-api-key"] = key
        case let .oauth(accessToken, _, _):
            headers["authorization"] = "Bearer \(accessToken)"
            // NEEDS-VERIFICATION: OAuth beta header name/value for the Anthropic API.
            headers["anthropic-beta"] = "oauth-2025-04-20"
        }

        let body = try Self.encodeBody(request, model: model)
        return HTTPRequest(url: Self.endpoint, method: .post, headers: headers, body: body)
    }

    /// Build the JSON body. System messages are hoisted into a top-level
    /// `system` field; the rest are sent as `messages`.
    static func encodeBody(_ request: ChatRequest, model: String) throws -> Data {
        var payload: [String: Any] = [
            "model": model,
            "max_tokens": request.maxOutputTokens,
            "stream": true,
        ]

        // Collect non-system messages.
        var messages: [[String: Any]] = []
        var hoistedSystemTexts: [String] = []
        for message in request.messages {
            switch message.role {
            case .system:
                hoistedSystemTexts.append(message.content)
            case .user:
                messages.append(["role": "user", "content": message.content])
            case .assistant:
                messages.append(["role": "assistant", "content": message.content])
            }
        }
        payload["messages"] = messages

        // System field as an array of text blocks (always the same shape). Any
        // explicit system instructions come first; the large cacheable prefix
        // (e.g. the whole book) goes last and carries the cache breakpoint, so
        // the instructions are cached along with it.
        var systemBlocks: [[String: Any]] = hoistedSystemTexts.map {
            ["type": "text", "text": $0]
        }
        if let prefix = request.cacheableSystemPrefix {
            systemBlocks.append([
                "type": "text",
                "text": prefix,
                "cache_control": ["type": "ephemeral"],
            ])
        }
        if !systemBlocks.isEmpty {
            payload["system"] = systemBlocks
        }

        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    // MARK: - Response parsing

    /// Extract the text delta from a `content_block_delta` event payload.
    static func textDelta(from json: String) -> String? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (object["type"] as? String) == "content_block_delta",
            let delta = object["delta"] as? [String: Any],
            let text = delta["text"] as? String
        else { return nil }
        return text
    }
}
