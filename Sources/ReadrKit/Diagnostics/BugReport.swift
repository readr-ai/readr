import Foundation

/// The facts about *this* install that triage always needs first.
/// Supplied by the app — `ReadrKit` builds on platforms that have no idea what
/// a device model is.
public struct BugReportEnvironment: Sendable, Equatable {
    public var appVersion: String
    public var build: String
    public var osVersion: String
    public var deviceModel: String

    public init(appVersion: String, build: String, osVersion: String, deviceModel: String) {
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.deviceModel = deviceModel
    }
}

/// Builds the report body a reader sends from Settings (#41).
///
/// Shaped for a human to read at the top and a maintainer to scroll at the
/// bottom: the reader's own words lead, the environment follows, diagnostics
/// last. Everything is redacted again on the way out — this string is about to
/// leave the device, and belt-and-braces is cheap.
public enum BugReportComposer {

    /// The longest report worth putting on a clipboard or in a share sheet.
    /// Diagnostics are trimmed from the oldest end to fit.
    public static let maxReportLength = 6_000

    public static let subject = "Readr bug report"

    /// How much of the report the reader's own description may occupy.
    ///
    /// It used to be unbudgeted, so a long description ate the whole allowance
    /// and the final `prefix` took the environment block, the diagnostics and
    /// even the "N events omitted" notice with it — leaving a report with no
    /// version, no device and no evidence, and nothing saying so. The cap
    /// scales down with `maxLength` for the same reason: a short link budget
    /// must still carry the environment and at least a line of evidence.
    public static let maxDescriptionLength = 2_000

    public static func compose(
        environment: BugReportEnvironment,
        events: [DiagnosticEvent],
        userDescription: String?,
        maxLength: Int = maxReportLength
    ) -> String {
        var body = ""

        // The reader's description leads. Everything below it is evidence.
        let described = userDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionBudget = min(maxDescriptionLength, max(0, maxLength / 2))
        if var described, !described.isEmpty {
            if described.count > descriptionBudget {
                described = String(described.prefix(descriptionBudget))
                    + "\n…(description truncated)"
            }
            body += described + "\n\n"
        } else {
            body += "<!-- What went wrong? What did you expect instead? -->\n\n"
        }

        body += """
        ---
        Readr \(environment.appVersion) (\(environment.build))
        \(environment.osVersion) — \(environment.deviceModel)

        """

        body += "\nRecent diagnostics:\n"
        if events.isEmpty {
            body += "(no diagnostics recorded this session)\n"
        } else {
            body += render(events, within: maxLength - body.count)
        }

        // Redaction only ever shortens, and `render` keeps to its budget, so
        // this is a backstop for the environment block on an absurdly small
        // budget — never the mechanism by which a report is trimmed.
        let redacted = HTTPError.redactingSecrets(in: body)
        guard redacted.count > maxLength else { return redacted }
        return String(redacted.prefix(maxLength))
    }

    // MARK: - Evidence

    /// The events a report should carry, oldest first: everything the file
    /// sink read back that this session's in-memory log no longer holds, then
    /// the in-memory log itself.
    ///
    /// The file holds this session's events too (the sink writes every one),
    /// but only the ring buffer keeps their full-precision timestamps and
    /// untrimmed messages — so for the span the buffer covers, the buffer
    /// wins, and the file contributes what came before it: earlier sessions,
    /// and this session's events the buffer has already dropped. File
    /// timestamps are whole seconds (`DiagnosticsFileSink.line(for:)`), so the
    /// cut is made on the floor of the buffer's first timestamp; an event in
    /// that same second is taken from the buffer's side only.
    public static func evidence(
        fromFile fileEvents: [DiagnosticEvent],
        session: [DiagnosticEvent],
        sessionStart: Date
    ) -> [DiagnosticEvent] {
        let boundary = (session.first?.timestamp ?? sessionStart).timeIntervalSince1970.rounded(.down)
        return fileEvents.filter { $0.timestamp.timeIntervalSince1970 < boundary } + session
    }

    // MARK: - The tracker link

    /// The longest "new issue" URL worth handing to a browser. GitHub's front
    /// end rejects request lines past ~8KB with a 414, and the body rides
    /// percent-encoded — a report dense in em-dashes and JSON details
    /// encodes to three times its character count, so the budget is on the
    /// *encoded* URL, not the text.
    public static let maxURLBytes = 6_000

    /// A prefilled "new issue" link for the project's tracker, shortened to
    /// fit `maxURLBytes` by dropping the OLDEST diagnostics first (the newest
    /// are the failure being reported) and saying how many went. The
    /// description is budgeted down before the environment block ever is.
    ///
    /// Readr has no support inbox — triage happens in GitHub issues, and this
    /// puts the reader's report straight there with the diagnostics attached.
    public static func issueURL(
        repository: String = "readr-ai/readr",
        subject: String = subject,
        environment: BugReportEnvironment,
        events: [DiagnosticEvent],
        userDescription: String?
    ) -> URL? {
        func link(_ body: String) -> URL? { issueURL(repository: repository, subject: subject, body: body) }
        func fits(_ url: URL) -> Bool { url.absoluteString.utf8.count <= maxURLBytes }

        var budget = maxReportLength
        var body = compose(
            environment: environment, events: events, userDescription: userDescription, maxLength: budget
        )
        guard var url = link(body) else { return nil }
        // Encoded size is close to linear in the body, so one proportional
        // step lands near the budget; the loop only tightens from there.
        var passes = 0
        while !fits(url), budget > 200, passes < 8 {
            let encoded = url.absoluteString.utf8.count
            budget = max(200, min(budget * 3 / 4, budget * maxURLBytes / encoded * 9 / 10))
            body = compose(
                environment: environment, events: events, userDescription: userDescription, maxLength: budget
            )
            guard let next = link(body) else { return nil }
            url = next
            passes += 1
        }
        // A description of nothing but wide characters can defeat any text
        // budget; the link must still open, so the body is cut to the bytes.
        while !fits(url), !body.isEmpty {
            body = String(body.dropLast(max(1, body.count / 10)))
            guard let next = link(body) else { return nil }
            url = next
        }
        return url
    }

    private static func issueURL(repository: String, subject: String, body: String) -> URL? {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components?.url
    }

    // MARK: - Rendering

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// Newest events matter most, so the *oldest* are dropped when the budget
    /// runs out — and the report says how many, rather than silently
    /// truncating. The notice is reserved up front, so the result never
    /// overshoots `budget`.
    private static func render(_ events: [DiagnosticEvent], within budget: Int) -> String {
        let notice = "(\(events.count) earlier events omitted)\n"
        var remaining = budget - notice.count
        var lines: [String] = []
        var dropped = 0

        for event in events.reversed() {
            var line = "[\(timeFormatter.string(from: event.timestamp))] "
                + "\(event.level.rawValue.uppercased()) \(event.category.rawValue): \(event.message)"
            if let detail = event.detail, !detail.isEmpty {
                line += "\n    \(detail)"
            }
            if line.count + 1 > remaining {
                dropped = events.count - lines.count
                break
            }
            remaining -= line.count + 1
            lines.append(line)
        }

        var rendered = lines.reversed().joined(separator: "\n")
        if dropped > 0 {
            rendered = "(\(dropped) earlier events omitted)\n" + rendered
        }
        return rendered + "\n"
    }
}
