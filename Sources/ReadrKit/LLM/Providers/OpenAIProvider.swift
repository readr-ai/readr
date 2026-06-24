import Foundation

/// OpenAI Chat Completions provider with SSE streaming.
public struct OpenAIProvider: LLMProvider {
    public let info: ProviderInfo

    private let credentials: Credentials
    private let model: String
    private let http: HTTPClient

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    public init(
        credentials: Credentials,
        model: String = "gpt-4.1",
        http: HTTPClient = URLSessionHTTPClient(),
        contextBudget: Int = 128_000
    ) {
        self.credentials = credentials
        self.model = model
        self.http = http
        self.info = ProviderInfo(
            kind: .openAI,
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

    // MARK: - Request building

    private func makeRequest(_ request: ChatRequest) throws -> HTTPRequest {
        let token: String
        switch credentials {
        case let .apiKey(key):
            token = key
        case let .oauth(accessToken, _, _):
            token = accessToken
        }
        let headers: [String: String] = [
            "authorization": "Bearer \(token)",
            "content-type": "application/json",
        ]
        let body = try Self.encodeBody(request, model: model)
        return HTTPRequest(url: Self.endpoint, method: .post, headers: headers, body: body)
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
