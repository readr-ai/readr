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

    /// Mail bodies ride in a `mailto:` URL, which the OS will refuse past a
    /// certain length. Diagnostics are trimmed from the oldest end to fit.
    public static let maxReportLength = 6_000

    public static let subject = "Readr bug report"

    /// How much of the report the reader's own description may occupy.
    ///
    /// It used to be unbudgeted, so a long description ate the whole allowance
    /// and the final `prefix` took the environment block, the diagnostics and
    /// even the "N events omitted" notice with it — leaving a report with no
    /// version, no device and no evidence, and nothing saying so.
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
        if var described, !described.isEmpty {
            if described.count > maxDescriptionLength {
                described = String(described.prefix(maxDescriptionLength))
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
            body += render(events, within: maxLength - body.count - 32)
        }

        let redacted = HTTPError.redactingSecrets(in: body)
        guard redacted.count > maxLength else { return redacted }
        return String(redacted.prefix(maxLength))
    }

    /// The events a report should carry: earlier sessions from the file
    /// sink's read-back, then this session from the in-memory log.
    ///
    /// The file holds this session's events too (the sink writes every one),
    /// so anything stamped at or after `session.sessionStart` is dropped from
    /// the file side rather than listed twice. Oldest first throughout, so
    /// `compose` trims the earlier sessions before anything recent.
    public static func evidence(
        fromFile fileEvents: [DiagnosticEvent],
        session: DiagnosticsLog
    ) -> [DiagnosticEvent] {
        fileEvents.filter { $0.timestamp < session.sessionStart } + session.entries
    }

    /// The longest "new issue" URL worth handing to a browser. GitHub's front
    /// end rejects request lines past ~8KB with a 414, and the body rides
    /// percent-encoded — a report dense in em-dashes and JSON details
    /// encodes to three times its character count, so the budget is on the
    /// *encoded* URL, not the text.
    public static let maxURLBytes = 6_000

    /// A prefilled "new issue" link for the project's tracker, shortened to
    /// fit `maxURLBytes` by dropping the OLDEST diagnostics first (the newest
    /// are the failure being reported) and saying how many went. The
    /// description and the environment block always survive.
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
        var budget = maxReportLength
        while true {
            let body = compose(
                environment: environment, events: events,
                userDescription: userDescription, maxLength: budget
            )
            guard let url = issueURL(repository: repository, subject: subject, body: body) else {
                return nil
            }
            // Past the floor, the description alone is what's left; a link
            // that opens with less beats a report that never arrives.
            if url.absoluteString.utf8.count <= maxURLBytes || budget <= 500 { return url }
            budget = budget * 3 / 4
        }
    }

    /// The link for an already-composed body, untruncated. Prefer the
    /// `events:` overload, which fits the body to the URL budget.
    public static func issueURL(
        repository: String = "readr-ai/readr",
        subject: String = subject,
        body: String
    ) -> URL? {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components?.url
    }

    /// Newest events matter most, so the *oldest* are dropped when the budget
    /// runs out — and the report says how many, rather than silently
    /// truncating.
    private static func render(_ events: [DiagnosticEvent], within budget: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        var lines: [String] = []
        var used = 0
        var dropped = 0

        for event in events.reversed() {
            var line = "[\(formatter.string(from: event.timestamp))] "
                + "\(event.level.rawValue.uppercased()) \(event.category.rawValue): \(event.message)"
            if let detail = event.detail, !detail.isEmpty {
                line += "\n    \(detail)"
            }
            if used + line.count + 1 > budget {
                dropped = events.count - lines.count
                break
            }
            used += line.count + 1
            lines.append(line)
        }

        var rendered = lines.reversed().joined(separator: "\n")
        if dropped > 0 {
            rendered = "(\(dropped) earlier events omitted)\n" + rendered
        }
        return rendered + "\n"
    }
}
