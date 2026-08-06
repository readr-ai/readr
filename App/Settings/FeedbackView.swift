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
struct ReportBugView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    let log: DiagnosticsLog

    @State private var whatHappened = ""
    @State private var includeDiagnostics = true
    @State private var showingDiagnostics = false

    private var environment: BugReportEnvironment { .current }

    private var report: String {
        BugReportComposer.compose(
            environment: environment,
            events: includeDiagnostics ? log.entries : [],
            userDescription: whatHappened
        )
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
                            Text("App version, device, and recent errors. Never your books, highlights, questions, or keys.")
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

                    // Two ways out: file it where it gets triaged, or send it
                    // however the reader prefers.
                    if let url = BugReportComposer.issueURL(body: report) {
                        Link(destination: url) {
                            Label("Open a GitHub issue", systemImage: "arrow.up.right.square")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityIdentifier("feedback.github")
                    }

                    ShareLink(item: report) {
                        Label("Send another way", systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                    }
                    .accessibilityIdentifier("feedback.share")

                    Text("Readr has no support inbox — reports go to the public issue tracker, so please don't include anything private.")
                        .font(.caption2)
                        .foregroundStyle(theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background)
            .navigationTitle("Report a bug")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
