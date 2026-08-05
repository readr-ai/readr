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
        userDescription: String?
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
            body += render(events, within: maxReportLength - body.count - 32)
        }

        let redacted = HTTPError.redactingSecrets(in: body)
        guard redacted.count > maxReportLength else { return redacted }
        return String(redacted.prefix(maxReportLength))
    }

    /// A prefilled "new issue" link for the project's tracker.
    ///
    /// Readr has no support inbox — triage happens in GitHub issues, and this
    /// puts the reader's report straight there with the diagnostics attached.
    /// Query-encoded bodies ride in the URL, so this budget is tighter than
    /// `maxReportLength`: browsers and the OS both give up on very long URLs,
    /// and a truncated report beats a link that won't open.
    public static let maxURLBodyLength = 4_000

    public static func issueURL(
        repository: String = "readr-ai/readr",
        subject: String = subject,
        body: String
    ) -> URL? {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: subject),
            URLQueryItem(name: "body", value: String(body.prefix(maxURLBodyLength))),
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
