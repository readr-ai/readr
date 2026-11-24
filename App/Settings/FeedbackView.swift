import SwiftUI
import ReadrKit

#if canImport(UIKit)
import UIKit
#endif

/// Where readers send bugs (#41) and pass Readr on (#40).

// MARK: - This install

extension BugReportEnvironment {

    /// The facts triage needs, read from the bundle and the OS.
    static var current: BugReportEnvironment {
        let info = Bundle.main.infoDictionary
        return BugReportEnvironment(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info?["CFBundleVersion"] as? String ?? "unknown",
            osVersion: osDescription,
            deviceModel: hardwareModel
        )
    }

    private static var osDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if os(iOS)
        return "\(UIDevice.current.systemName) \(number)"
        #else
        return "macOS \(number)"
        #endif
    }

    /// The machine identifier ("iPhone17,1", "Mac15,3") rather than a marketing
    /// name — it's what maps a report to a screen size and a chip.
    private static var hardwareModel: String {
        #if os(iOS)
        // In a simulator `utsname.machine` is the *host* architecture, so a
        // report filed from one said "arm64" — true, and useless for triage.
        // The simulated device's real identifier is in the environment.
        if let simulated = ProcessInfo.processInfo
            .environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated + " (simulator)"
        }
        var system = utsname()
        uname(&system)
        let identifier = withUnsafeBytes(of: &system.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return identifier.isEmpty ? "unknown" : identifier
        #else
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
        #endif
    }
}

// MARK: - Sharing Readr

enum ReadrShare {
    /// The public beta link. Becomes the App Store listing once Readr is live.
    static let joinURL = URL(string: "https://testflight.apple.com/join/U5dBEsSG")!

    static let message = """
    Readr — an ebook reader you can ask about the book you're reading. \
    Highlights turn into articles. Free beta:
    """
}

// MARK: - Reporting a bug
/// Compose a report, see exactly what it contains, then send it.
///
/// The diagnostics are shown in full rather than summarised: a reader is about
/// to publish this to a public issue tracker, and "attaches a redacted
/// diagnostic log" is a claim they should be able to check for themselves.
///
/// Nothing here transmits anything. The report leaves the device only by the
/// reader's own hand — a prefilled tracker link, the clipboard, or the share
/// sheet — and each of those used to lose it in its own way (a GitHub login
/// wall, the GitHub app ignoring prefilled text, a URL too long to open, the
/// newest events cut off the end). So: the link is fitted to what a browser
/// will open, the tracker button copies the report first and says so in its
/// label, and the log can be shared as a file — a snapshot of both
/// generations, so it never says less than the report does.
struct ReportBugView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    let log: DiagnosticsLog
    /// Where earlier sessions' evidence comes from. Nil means the sink the
    /// app installed (resolved on the main actor when the sheet appears);
    /// previews and tests that want this session only pass an empty sink.
    var fileSink: DiagnosticsFileSink?

    @State private var whatHappened = ""
    @State private var includeDiagnostics = true
    @State private var showingDiagnostics = false
    /// Read once, off the main actor, when the sheet appears: the file is up
    /// to two megabytes and the parse is thousands of date conversions.
    @State private var evidence: [DiagnosticEvent] = []
    @State private var evidenceLoaded = false
    /// A copy of the log file for the share sheet, taken when the sheet
    /// appears so a rotation mid-share can't pull it away.
    @State private var logSnapshot: URL?
    /// The composed report, refreshed when its inputs change — not on every
    /// body pass, which happens per keystroke.
    @State private var report = ""
    @State private var copied = false

    private var environment: BugReportEnvironment { .current }

    private var events: [DiagnosticEvent] { includeDiagnostics ? evidence : [] }

    private func refreshReport() {
        report = BugReportComposer.compose(
            environment: environment, events: events, userDescription: whatHappened
        )
        // Whatever was copied is no longer what the screen shows.
        copied = false
    }

    private func loadEvidence() async {
        guard !evidenceLoaded else { return }
        evidenceLoaded = true
        let sink = fileSink ?? AppModel.diagnosticsFileSink
        let session = log.entries
        let start = log.sessionStart
        let (fromFile, snapshot) = await Task.detached(priority: .userInitiated) {
            (sink?.readBack() ?? [], sink?.snapshotForSharing())
        }.value
        evidence = BugReportComposer.evidence(fromFile: fromFile, session: session, sessionStart: start)
        logSnapshot = snapshot
        refreshReport()
    }

    private func copyReport() {
        Pasteboard.copy(report)
        copied = true
    }

    /// Copy, then open the tracker: GitHub's sign-in redirect and its iOS
    /// app both drop the prefilled text, and a reader who pastes still gets
    /// it there. The label says both things, so the clipboard is never
    /// overwritten by surprise.
    private func copyAndOpenIssue() {
        copyReport()
        // Fitted to the URL budget on tap — composing to bytes is the
        // expensive path, and only this button needs it.
        if let url = BugReportComposer.issueURL(
            environment: environment, events: events, userDescription: whatHappened
        ) {
            openURL(url)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("What went wrong?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.inkColor)

                    Text("What you did, what you expected, and what happened instead.")
                        .font(.caption)
                        .foregroundStyle(theme.muted)

                    TextEditor(text: $whatHappened)
                        .font(.body)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.line, lineWidth: 1)
                        )
                        .accessibilityIdentifier("feedback.description")

                    Toggle(isOn: $includeDiagnostics) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Include diagnostics")
                                .font(.subheadline)
                                .foregroundStyle(theme.inkColor)
                            Text("App version, device, and recent errors from this and earlier sessions. Never your books, highlights, questions, or keys.")
                                .font(.caption)
                                .foregroundStyle(theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("feedback.includeDiagnostics")

                    if includeDiagnostics {
                        Button {
                            showingDiagnostics.toggle()
                        } label: {
                            Label(
                                showingDiagnostics ? "Hide what will be sent" : "See exactly what will be sent",
                                systemImage: showingDiagnostics ? "chevron.down" : "chevron.right"
                            )
                            .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.muted)
                        .accessibilityIdentifier("feedback.preview")

                        if showingDiagnostics {
                            ScrollView(.horizontal) {
                                Text(report)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(theme.muted)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 220)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8).fill(theme.line.opacity(0.25))
                            )
                        }
                    }

                    Divider().overlay(theme.line)

                    // Ways out: file it where it gets triaged, keep a copy,
                    // or send it however the reader prefers.
                    Button(action: copyAndOpenIssue) {
                        Label("Copy report and open a GitHub issue", systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.iris)
                    .accessibilityAddTraits(.isLink)
                    .accessibilityHint("Copies the report, then opens GitHub in your browser")
                    .accessibilityIdentifier("feedback.github")

                    Button(action: copyReport) {
                        Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.inkColor)
                    .accessibilityIdentifier("feedback.copy")

                    ShareLink(item: report) {
                        Label("Send another way", systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                    }
                    .accessibilityIdentifier("feedback.share")

                    if includeDiagnostics, let logSnapshot {
                        ShareLink(item: logSnapshot) {
                            Label("Share the full log file", systemImage: "doc.text")
                                .font(.subheadline)
                        }
                        .accessibilityIdentifier("feedback.shareLog")
                        Text("The whole diagnostics log, including events too old for the report above — same rules: shape only, never your text.")
                            .font(.caption2)
                            .foregroundStyle(theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Readr has no support inbox — reports go to the public issue tracker, so please don't include anything private. If GitHub opens without your report (it asks you to sign in first, and its app ignores prefilled text), paste it: the report is on your clipboard.")
                        .font(.caption2)
                        .foregroundStyle(theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background)
            .task { await loadEvidence() }
            .onAppear(perform: refreshReport)
            .onChange(of: whatHappened) { _, _ in refreshReport() }
            .onChange(of: includeDiagnostics) { _, _ in refreshReport() }
            .navigationTitle("Report a bug")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
