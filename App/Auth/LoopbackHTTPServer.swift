import Foundation
import Network

/// A loopback HTTP server that captures the OAuth redirect. The browser is sent
/// to `127.0.0.1:<port><callbackPath>?...`; we read that request, hand back the
/// full callback URL, and reply with a "you can close this" page. Used because
/// the providers use loopback redirect URIs (the Codex/Zed pattern), which
/// `ASWebAuthenticationSession` can't intercept.
///
/// Only a request to the exact `expectedPath` completes the flow; other requests
/// the browser/OS may make to the port (favicon, speculative pre-connects) get a
/// 404 and the server keeps listening for the real callback.
final class LoopbackHTTPServer {
    private var listener: NWListener?
    private let port: UInt16
    private var didComplete = false

    init(port: UInt16) {
        self.port = port
    }

    func start(
        redirectBase: String,
        expectedPath: String,
        onCallback: @escaping (Result<URL, Error>) -> Void
    ) {
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw LoopbackError.invalidPort
            }
            // Bind to the loopback interface (127.0.0.1) ONLY. Without a
            // `requiredLocalEndpoint`, `NWListener` binds to every interface
            // (the equivalent of `INADDR_ANY` / `0.0.0.0`), which would expose
            // the OAuth callback port to the local network. Pinning the local
            // endpoint to `127.0.0.1` keeps the redirect reachable only from
            // this machine.
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback), port: nwPort
            )
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                // Defence in depth: even though we bind loopback-only, reject
                // any connection whose remote endpoint isn't loopback before
                // reading a single byte.
                guard Self.isLoopbackEndpoint(connection.endpoint) else {
                    connection.cancel()
                    return
                }
                connection.start(queue: .main)
                self?.readRequestLine(
                    connection, accumulated: Data(),
                    redirectBase: redirectBase, expectedPath: expectedPath, onCallback: onCallback
                )
            }
            listener.start(queue: .main)
        } catch {
            onCallback(.failure(error))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Read until the HTTP request line (terminated by CRLF) is complete; the
    /// line can arrive split across multiple TCP segments.
    private func readRequestLine(
        _ connection: NWConnection,
        accumulated: Data,
        redirectBase: String,
        expectedPath: String,
        onCallback: @escaping (Result<URL, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil { connection.cancel(); return }

            var buffer = accumulated
            if let data { buffer.append(data) }

            if let text = String(data: buffer, encoding: .utf8),
               let lineEnd = text.range(of: "\r\n") {
                let requestLine = String(text[text.startIndex..<lineEnd.lowerBound])
                self.process(
                    requestLine: requestLine, connection: connection,
                    redirectBase: redirectBase, expectedPath: expectedPath, onCallback: onCallback
                )
            } else if isComplete {
                connection.cancel()
            } else {
                self.readRequestLine(
                    connection, accumulated: buffer,
                    redirectBase: redirectBase, expectedPath: expectedPath, onCallback: onCallback
                )
            }
        }
    }

    private func process(
        requestLine: String,
        connection: NWConnection,
        redirectBase: String,
        expectedPath: String,
        onCallback: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let target = Self.requestTarget(requestLine),
              let url = URL(string: redirectBase + target) else {
            respond(status: "400 Bad Request", body: "Bad request", on: connection)
            return
        }
        guard url.path == expectedPath else {
            // Not the OAuth callback (e.g. /favicon.ico) — ignore, keep listening.
            respond(status: "404 Not Found", body: "Not found", on: connection)
            return
        }
        let body = "<html><body style=\"font-family:-apple-system;padding:3rem;text-align:center\">"
            + "<h2>Signed in to Readr</h2><p>You can close this tab and return to the app.</p></body></html>"
        respond(status: "200 OK", body: body, contentType: "text/html; charset=utf-8", on: connection)
        finish(.success(url), onCallback: onCallback)
    }

    private func respond(
        status: String,
        body: String,
        contentType: String = "text/plain; charset=utf-8",
        on connection: NWConnection
    ) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        // Cancel only after the bytes are flushed, so the browser actually
        // receives the page.
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(
        _ result: Result<URL, Error>,
        onCallback: @escaping (Result<URL, Error>) -> Void
    ) {
        guard !didComplete else { return }
        didComplete = true
        onCallback(result)
        stop()
    }

    /// Extract the request target ("/auth/callback?...") from a request line.
    static func requestTarget(_ requestLine: String) -> String? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    /// Whether a connection's remote endpoint is the loopback interface.
    /// Non-host endpoints (or any non-loopback address) are rejected so the
    /// callback server never talks to anything off this machine.
    static func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.isLoopback
        case .ipv6(let address):
            return address.isLoopback
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }

    enum LoopbackError: Error { case invalidPort }
}
