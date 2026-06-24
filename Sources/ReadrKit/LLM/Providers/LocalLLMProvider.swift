import Foundation

/// On-device provider backed by an Ollama-compatible server (zero egress).
///
/// Ollama streams newline-delimited JSON objects (NOT SSE `data:` frames), so
/// each streamed line is parsed directly as JSON.
public struct LocalLLMProvider: LLMProvider {
    public let info: ProviderInfo

    private let model: String
    private let baseURL: URL
    private let http: HTTPClient

    public init(
        model: String = "llama3",
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        http: HTTPClient = URLSessionHTTPClient(),
        contextBudget: Int = 8_192
    ) {
        self.model = model
        self.baseURL = baseURL
        self.http = http
        self.info = ProviderInfo(
            kind: .local,
            modelID: model,
            contextBudget: contextBudget,
            supportsPromptCaching: false,
            isLocal: true
        )
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let httpRequest = try makeRequest(request)
                    let lines = try await http.stream(httpRequest)
                    for try await line in lines {
                        guard let object = Self.parseLine(line) else { continue }
                        if let message = object["message"] as? [String: Any],
                           let content = message["content"] as? String,
                           !content.isEmpty {
                            continuation.yield(ChatChunk(textDelta: content))
                        }
                        if (object["done"] as? Bool) == true {
                            continuation.finish()
                            return
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
        let url = baseURL.appendingPathComponent("api/chat")
        let headers = ["content-type": "application/json"]
        let body = try Self.encodeBody(request, model: model)
        return HTTPRequest(url: url, method: .post, headers: headers, body: body)
    }

    static func encodeBody(_ request: ChatRequest, model: String) throws -> Data {
        var messages: [[String: Any]] = []
        if let prefix = request.cacheableSystemPrefix {
            messages.append(["role": "system", "content": prefix])
        }
        for message in request.messages {
            messages.append(["role": message.role.rawValue, "content": message.content])
        }
        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    // MARK: - Response parsing

    /// Parse one newline-delimited JSON line into an object.
    static func parseLine(_ line: Data) -> [String: Any]? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return nil }
        return object
    }
}
