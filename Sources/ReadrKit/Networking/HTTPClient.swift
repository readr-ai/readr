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
extension HTTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .status(let code, let body):
            var message: String
            switch code {
            case 401, 403:
                message = "The provider rejected your API key (HTTP \(code)). Check the key in Settings → AI Providers."
            case 429:
                message = "The provider rate-limited this request (HTTP 429). Wait a moment and try again."
            case 400, 413:
                message = "The provider rejected the request (HTTP \(code)) — the book or question may be too large for this model."
            case 500...:
                message = "The provider had trouble responding (HTTP \(code)). Try again shortly."
            default:
                message = "The provider returned HTTP \(code)."
            }
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty {
                message += " Details: \(detail.prefix(200))"
            }
            return message
        case .nonHTTPResponse:
            return "Unexpected response from the provider — check your network connection and try again."
        case .transport(let code):
            switch code {
            case .timedOut:
                return "The request to the provider timed out."
            case .notConnectedToInternet:
                return "You appear to be offline."
            case .cannotConnectToHost, .cannotFindHost:
                return "Couldn't reach the provider."
            case .networkConnectionLost:
                return "The network connection was lost while talking to the provider."
            default:
                return "The network request failed (\(code.rawValue))."
            }
        }
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
