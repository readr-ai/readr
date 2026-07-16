import Foundation

/// On-device provider backed by an Ollama-compatible server (zero egress).
///
/// Ollama streams newline-delimited JSON objects (NOT SSE `data:` frames), so
/// each streamed line is parsed directly as JSON.
public struct LocalLLMProvider: LLMProvider, LocalReadinessProbing {
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

    // MARK: - Readiness probe

    /// The outcome of probing the local Ollama server. Drives the readiness
    /// state the UI shows for the on-device provider.
    public enum ProbeResult: Sendable, Equatable {
        /// The server responded and the requested model tag is installed.
        case ready
        /// The server is reachable but the requested model is not installed.
        /// `available` lists the tags the server does have, for a helpful hint.
        case modelMissing(requested: String, available: [String])
        /// Nothing is listening on the Ollama port (connection refused / offline).
        case notRunning
    }

    /// Probe the local Ollama server at `baseURL` via `GET /api/tags`, and
    /// classify the result as `.notRunning` (connection refused), `.modelMissing`
    /// (server up but the requested tag isn't installed), or `.ready`. Reuses the
    /// injected `HTTPClient`, so it is fully mockable in tests.
    public func probe() async -> ProbeResult {
        let url = baseURL.appendingPathComponent("api/tags")
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(url: url, method: .get))
        } catch {
            // Connection refused / offline / any transport failure: the server
            // isn't reachable, so treat it as not running.
            return .notRunning
        }
        guard response.isSuccess else { return .notRunning }
        let installed = Self.installedTags(from: response.body)
        if Self.tagList(installed, contains: model) {
            return .ready
        }
        return .modelMissing(requested: model, available: installed)
    }

    /// Parse the `models[].name` tags out of an `/api/tags` response body.
    static func installedTags(from body: Data) -> [String] {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let models = object["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    /// Ollama tags carry an implicit `:latest` suffix, so `llama3` matches an
    /// installed `llama3:latest` (and vice versa).
    private static func tagList(_ tags: [String], contains model: String) -> Bool {
        let wanted = normalize(model)
        return tags.contains { normalize($0) == wanted }
    }

    private static func normalize(_ tag: String) -> String {
        tag.hasSuffix(":latest") ? String(tag.dropLast(":latest".count)) : tag
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
