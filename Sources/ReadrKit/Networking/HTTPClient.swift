import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP transport abstraction so providers and the OAuth client are
/// testable with a mock and never hit the network in unit tests. Production uses
/// `URLSessionHTTPClient`; tests use `MockHTTPClient` / `NetworkSentinel`.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    /// Line-delimited byte stream for Server-Sent Events (token streaming).
    func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error>
}

public struct HTTPRequest: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST", delete = "DELETE" }
    public var url: URL
    public var method: Method
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: Method = .get, headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }

    /// Throw `HTTPError.status(_:body:)` (decoding the body as UTF-8) unless the
    /// response is a 2xx success. Shared by the provider credential checks so the
    /// "reject non-2xx" mapping is defined once.
    public func throwIfUnsuccessful() throws {
        guard isSuccess else {
            throw HTTPError.status(status, body: String(decoding: body, as: UTF8.self))
        }
    }
}

public enum HTTPError: Error, Sendable, Equatable {

    /// Whether a 429 body reports an exhausted quota (permanent until the user
    /// fixes billing) rather than an ordinary rate limit (transient). Providers
    /// reuse the status code for both, so the body is the only signal.
    public static func indicatesQuotaExhausted(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return lowered.contains("insufficient_quota")
            || lowered.contains("exceeded your current quota")
    }

    case status(Int, body: String)
    case nonHTTPResponse
    /// A Foundation `URLError` (timeout, offline, host unreachable, …) raised by
    /// the transport before any HTTP status was seen. Wrapping it here lets the
    /// UI show an actionable sentence instead of Foundation's generic
    /// "The operation couldn't be completed." Stores the `URLError.Code` so the
    /// error stays `Equatable`/`Sendable`.
    case transport(URLError.Code)
}

/// These errors render verbatim in the Ask panel and Article Studio, so each
/// case maps to a sentence a reader can act on rather than Foundation's
/// generic "The operation couldn't be completed".
///
/// Nothing from the wire appears here. Status codes and raw bodies are real
/// triage material but they are not something a reader can act on, so they
/// live in `diagnosticSummary` and travel with bug reports instead
/// (#48). Pinned by `PlainLanguageErrorTests`.
extension HTTPError: LocalizedError, DiagnosticallyDescribable {
    public var errorDescription: String? {
        switch self {
        case .status(let code, let body):
            var message: String
            switch code {
            case 401, 403:
                message = "Your API key was rejected. Check it in Settings → AI Providers."
            case 429:
                // 429 covers two opposite conditions. A rate limit clears on
                // its own; an exhausted quota needs a billing change, so
                // "try again" would send the reader in circles.
                if HTTPError.indicatesQuotaExhausted(body) {
                    message = "Your provider account is out of credit. Check your plan and billing — waiting won't clear this one."
                } else {
                    message = "You're sending questions faster than this provider allows. Wait a moment and try again."
                }
            case 400, 413:
                message = "This book or question is too large for the model you've picked. Try a shorter question or a model with a bigger context window."
            case 500...:
                message = "The provider is having trouble right now. Try again in a moment."
            default:
                message = "The provider couldn't handle that request."
            }
            if let detail = HTTPError.readableDetail(from: body) {
                message += " The provider said: \(detail)"
            }
            return message
        case .nonHTTPResponse:
            return "Got an unexpected reply from the provider. Check your connection and try again."
        case .transport(let code):
            switch code {
            case .timedOut:
                return "The provider took too long to reply."
            case .notConnectedToInternet:
                return "You appear to be offline."
            case .cannotConnectToHost, .cannotFindHost:
                return "Couldn't reach the provider."
            case .networkConnectionLost:
                return "The connection dropped while waiting for the provider."
            default:
                return "Couldn't complete the request to the provider."
            }
        }
    }

    /// The wire detail, for logs and bug reports — never shown in the UI.
    /// Secrets are stripped here too: this string is written to disk and
    /// attached to reports (CLAUDE.md — secrets never in logs).
    public var diagnosticSummary: String {
        switch self {
        case .status(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "HTTP \(code)" }
            let safe = HTTPError.redactingSecrets(in: trimmed)
            return "HTTP \(code) — \(safe.prefix(500))"
        case .nonHTTPResponse:
            return "Non-HTTP response"
        case .transport(let code):
            return "Transport failure: \(HTTPError.transportName(code)) (\(code.rawValue))"
        }
    }

    /// A readable name for a `URLError.Code`, so diagnostics don't reduce to a
    /// bare negative number that means nothing without a lookup table.
    static func transportName(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: return "timed out"
        case .notConnectedToInternet: return "not connected to internet"
        case .cannotConnectToHost: return "cannot connect to host"
        case .cannotFindHost: return "cannot find host"
        case .networkConnectionLost: return "network connection lost"
        case .badServerResponse: return "bad server response"
        case .secureConnectionFailed: return "secure connection failed"
        default: return "URLError"
        }
    }

    /// The one useful sentence inside a provider's error body.
    ///
    /// Providers wrap it in a JSON envelope (`{"error":{"message":"…"}}`) or,
    /// on a bad gateway, in HTML. Neither belongs in front of a reader, so this
    /// returns the message field when there is one and `nil` otherwise —
    /// showing nothing beats showing an envelope.
    static func readableDetail(from body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate: String?
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            candidate = Self.messageField(in: json)
        } else if !trimmed.contains("<"), !trimmed.contains("{") {
            // A provider that answered in plain prose.
            candidate = trimmed
        }

        guard var message = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty
        else { return nil }

        message = redactingSecrets(in: message)
        if message.count > 200 {
            message = String(message.prefix(200)).trimmingCharacters(in: .whitespaces) + "…"
        }
        // Keep it a sentence — these are appended after a colon.
        if let last = message.last, !".!?…".contains(last) { message += "." }
        return message
    }

    /// Digs `message` out of the shapes providers actually send: a top-level
    /// field, or one nested under `error`.
    private static func messageField(in json: [String: Any]) -> String? {
        if let message = json["message"] as? String { return message }
        if let error = json["error"] as? [String: Any] {
            return error["message"] as? String
        }
        if let error = json["error"] as? String { return error }
        return nil
    }

    /// Blanks anything key-shaped. Providers echo the rejected credential back
    /// in their message, and this text ends up in logs and bug reports.
    static func redactingSecrets(in text: String) -> String {
        let patterns = [
            // Vendor-prefixed keys: sk-…, sk-ant-api03-…, and friends.
            "\\b(sk|rk|pk|key)-[A-Za-z0-9_-]{8,}",
            // Bearer tokens.
            "\\bBearer\\s+[A-Za-z0-9._-]{16,}",
            // Long opaque runs — key material by shape. Deliberately narrower
            // than "40+ word characters": including `-` in that class made it
            // eat ordinary hyphenated prose, and this runs over the reader's
            // own free text in a bug report, so
            // "state-of-the-art-transformer-language-model" came back as
            // `[redacted]`. Real key material is an unbroken alphanumeric run
            // mixing both cases or digits, so require that instead.
            "\\b(?=[A-Za-z0-9]*[0-9])(?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]{32,}\\b",
        ]
        var redacted = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            redacted = regex.stringByReplacingMatches(
                in: redacted,
                range: NSRange(redacted.startIndex..., in: redacted),
                withTemplate: "[redacted]"
            )
        }
        return redacted
    }

    /// A concrete next step for the reader, shown beneath `errorDescription`.
    public var recoverySuggestion: String? {
        switch self {
        case .status(let code, _):
            switch code {
            case 401, 403:
                return "Open Settings → AI Providers and re-enter or refresh your API key."
            case 429:
                return "Wait a few seconds and try again."
            case 400, 413:
                return "Try a shorter question or a model with a larger context window."
            case 500...:
                return "The provider is having trouble. Wait a moment and retry."
            default:
                return nil
            }
        case .nonHTTPResponse:
            return "Check your network connection and try again."
        case .transport(let code):
            switch code {
            case .timedOut:
                return "Check your connection and try again; the provider may be slow to respond."
            case .notConnectedToInternet:
                return "Reconnect to the internet, then try again."
            case .cannotConnectToHost, .cannotFindHost:
                return "Check your internet connection or try again shortly — the provider may be temporarily unavailable."
            case .networkConnectionLost:
                return "Check your connection and try again."
            default:
                return "Check your network connection and try again."
            }
        }
    }
}

/// `URLSession`-backed transport.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request.urlRequest)
        } catch let error as URLError {
            throw HTTPError.transport(error.code)
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.nonHTTPResponse }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k] = v }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }

    public func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation (Linux) has no `URLSession.bytes` — there
        // is no incremental-bytes API to wrap. Linux only needs this path to
        // COMPILE for CI (unit tests use `MockHTTPClient`, never the network):
        // fetch the whole body, then replay it line-by-line.
        let response = try await send(request)
        guard (200..<300).contains(response.status) else {
            throw HTTPError.status(response.status, body: "")
        }
        return AsyncThrowingStream { continuation in
            let text = String(decoding: response.body, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                continuation.yield(Data(line.utf8))
            }
            continuation.finish()
        }
        #else
        let (bytes, response) = try await session.bytes(for: request.urlRequest)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.nonHTTPResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode, body: "")
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(Data(line.utf8))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        #endif
    }
}

extension HTTPRequest {
    var urlRequest: URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method.rawValue
        req.httpBody = body
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        return req
    }
}
