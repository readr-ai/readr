import SwiftUI
import ReadrKit
#if os(iOS)
import UIKit
#endif

/// The narration bar: what the reader sees while the book is being read aloud.
///
/// It sits under the page as a safe-area inset rather than floating over it —
/// listening and reading happen together (the page turns itself to follow the
/// voice), so the bar must never cover the words being spoken. Styling follows
/// the reading theme, so switching to Night doesn't leave a bright slab at the
/// bottom of the page.
struct ListenBar: View {
    @ObservedObject var narration: NarrationModel
    let style: ReaderStyle
    /// Close the bar and end narration.
    let onClose: () -> Void

    private var theme: ReadingTheme { style.theme }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.line).frame(height: 1)
            progressTrack
            HStack(spacing: 12) {
                transportControls
                statusLine
                Spacer(minLength: 8)
                aheadFigure
                speedMenu
                voiceMenu
                sleepMenu
                closeButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(theme.elevated)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("listen.bar")
        .accessibilityLabel("Narration controls")
    }

    // MARK: - Transport

    private var transportControls: some View {
        HStack(spacing: 4) {
            control(
                "backward.end", id: "listen.previousChapter", label: "Previous chapter",
                help: "Previous chapter"
            ) { narration.previousChapter() }
            control(
                "backward", id: "listen.previous", label: "Previous sentence",
                help: "Previous sentence"
            ) { narration.skipBackward() }
            // Preparing shows Pause too: the voice is on its way and the
            // control pauses the wait, the way it pauses speech.
            Button { narration.togglePlayPause() } label: {
                Image(systemName: narration.isUnderway ? "pause.fill" : "play.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.inkColor)
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("listen.playPause")
            .accessibilityLabel(narration.isUnderway ? "Pause" : "Play")
            .help(narration.isUnderway ? "Pause narration" : "Play narration")
            control(
                "forward", id: "listen.next", label: "Next sentence",
                help: "Next sentence"
            ) { narration.skipForward() }
            control(
                "forward.end", id: "listen.nextChapter", label: "Next chapter",
                help: "Next chapter"
            ) { narration.nextChapter() }
        }
    }

    private func control(
        _ symbol: String, id: String, label: String, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
        .help(help)
    }

    // MARK: - Status line

    /// What the middle of the bar says: the wait for the Readr Voice model,
    /// a failed download with its Retry, or — nearly always — the sentence
    /// being read.
    @ViewBuilder
    private var statusLine: some View {
        if narration.isPreparing {
            preparingLine
        } else if narration.readrVoiceFailed, !narration.isUnderway {
            failedLine
        } else if let holdText = narration.holdText {
            holdLine(holdText)
        } else {
            sentenceLine
        }
    }

    /// Narration paused on its own — with the screen locked, nothing was
    /// ready for the next sentence. Unlocking resumes it; this is for the
    /// reader who has just done that and wants to know why it stopped.
    private func holdLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(theme.muted)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 420, alignment: .leading)
            .accessibilityIdentifier("listen.hold")
            .accessibilityLabel(text)
    }

    /// How much Readr Voice audio is already made for what follows — the
    /// quiet reassurance that a locked screen has something to play from.
    /// Shown from a minute up; nothing worth saying below that.
    @ViewBuilder
    private var aheadFigure: some View {
        if narration.usesReadrVoice, let label = Self.aheadLabel(seconds: narration.secondsAhead) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("listen.ahead")
                .accessibilityLabel("\(label) in Readr Voice")
                .help("Readr Voice audio already prepared for what follows")
        }
    }

    /// "48 min ready", "1 h 12 min ready"; nil under a minute.
    static func aheadLabel(seconds: TimeInterval) -> String? {
        let minutes = Int(seconds / 60)
        guard minutes >= 1 else { return nil }
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "\(hours) h ready" : "\(hours) h \(rest) min ready"
        }
        return "\(minutes) min ready"
    }

    /// The first Listen's one-time download, with the download library's
    /// progress while it reports one and an indeterminate spinner for the
    /// rest (the pronunciation assets and weight load). No Apple voice reads
    /// meanwhile; narration starts the moment the weights are in.
    private var preparingLine: some View {
        HStack(spacing: 8) {
            if let progress = narration.readrVoiceDownloadProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(theme.iris)
                    .frame(width: 64)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.muted)
            }
            Text(preparingText)
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("listen.preparing")
        .accessibilityLabel(preparingText)
    }

    private var preparingText: String {
        if let progress = narration.readrVoiceDownloadProgress {
            return "Preparing Readr Voice\u{2026} \(Int((progress * 100).rounded()))% "
                + "of \(narration.readrVoiceDownloadSize), once"
        }
        return "Preparing Readr Voice\u{2026} \(narration.readrVoiceDownloadSize), once"
    }

    /// The download failed (or a synthesis hung). Narration is paused on
    /// the sentence; Retry fetches again and picks it back up. An Apple
    /// voice is a pick away under "Other voices", never automatic.
    private var failedLine: some View {
        HStack(spacing: 8) {
            Text("Readr Voice couldn\u{2019}t download.")
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Button("Retry") { narration.retryReadrVoice() }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.iris)
                .buttonStyle(.plain)
                .accessibilityIdentifier("listen.retry")
                .accessibilityLabel("Retry the Readr Voice download")
                .help("Download Readr Voice again and keep listening")
        }
        .frame(maxWidth: 420, alignment: .leading)
        .accessibilityIdentifier("listen.failed")
    }

    /// The sentence being spoken. The page follows the voice on its own, so
    /// this is a confirmation of *where* rather than the only way to tell.
    private var sentenceLine: some View {
        Text(narration.currentSentence)
            .font(.system(size: 12, design: .serif))
            .italic()
            .foregroundStyle(theme.muted)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 420, alignment: .leading)
            .accessibilityIdentifier("listen.sentence")
            .accessibilityLabel("Now reading: \(narration.currentSentence)")
    }

    private var progressTrack: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(theme.line)
                Rectangle()
                    .fill(theme.iris)
                    .frame(width: geometry.size.width * min(max(narration.chapterProgress, 0), 1))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }

    // MARK: - Voice controls

    private var osName: String {
        #if os(iOS)
        UIDevice.current.systemName
        #else
        "macOS"
        #endif
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: speedBinding) {
                ForEach(SpeechSettings.rateSteps, id: \.self) { step in
                    Text(SpeechSettings.rateLabel(step)).tag(step)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(SpeechSettings.rateLabel(narration.rate))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.inkColor)
                .monospacedDigit()
                .frame(minWidth: 34)
        }
        .fixedSize()
        .accessibilityIdentifier("listen.speed")
        .accessibilityLabel("Speaking speed")
        .help("Speaking speed")
    }

    private var speedBinding: Binding<Double> {
        Binding(get: { narration.rate }, set: { narration.setRate($0) })
    }

    private var voiceMenu: some View {
        Menu {
            // Notes go above the list, not below it: the voice list is as
            // long as the reader has voices installed, and anything under it
            // is off the bottom of the menu — unreachable, and never even
            // rendered.
            menuNote("More voices: Settings \u{203A} Accessibility \u{203A} Spoken Content")
            // The failure note stays while Readr Voice is the selected
            // narrator: the bar carries the Retry, this says where it is.
            // (The old "downloading — switching automatically" note is gone:
            // the wait is the bar's preparing state now, and nothing
            // switches — Readr Voice reads from the first sentence.)
            if narration.readrVoiceFailed {
                menuNote(
                    "Readr Voice couldn\u{2019}t download or stopped responding \u{2014} "
                        + "Retry is on the Listen bar"
                )
            }
            // iPhone/iPad: the buffer plays with the screen locked and the
            // CPU refills it. Said once, up front, because 3.3.0 said the
            // opposite here and a reader who remembers that deserves the
            // correction where they read it.
            if narration.readrVoiceKeepsReadingWhenLocked, narration.usesReadrVoice {
                menuNote("Keeps reading with the screen locked")
            }
            // This is scoped to readers who would otherwise have Readr Voice:
            // an English book with no stored choice, or a stored Readr Voice.
            // An explicitly chosen Apple voice needs no warning about a voice
            // the reader did not ask for.
            if narration.readrVoiceUnavailable {
                menuNote(readrVoiceUnavailableNote)
            }
            Divider()
            if narration.voices.isEmpty {
                menuNote("No voices installed")
            } else if narration.readrVoiceOffered {
                // An English book where Readr Voice can run: Readr Voice is
                // the menu, checked, and the Apple voices sit behind a
                // disclosure. They are kept — an accessibility reader who
                // set one up keeps it, and a stored pick still shows checked
                // in there — but they are no longer a wall of rows between
                // the reader and the one voice this menu is about.
                Picker("Voice", selection: voiceBinding) {
                    ForEach(narration.voices.filter { KokoroSpeechEngine.isKokoroVoiceID($0.id) }) {
                        voice in
                        Text(voice.name).tag(Optional(voice.id))
                    }
                }
                .pickerStyle(.inline)
                Menu("Other voices\u{2026}") {
                    Picker("Other voices", selection: voiceBinding) {
                        ForEach(narration.platformVoices) { voice in
                            Text("\(voice.name) (\(voice.language))").tag(Optional(voice.id))
                        }
                    }
                    .pickerStyle(.inline)
                }
                .accessibilityIdentifier("listen.otherVoices")
            } else {
                Picker("Voice", selection: voiceBinding) {
                    ForEach(narration.voices) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(Optional(voice.id))
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
        }
        .fixedSize()
        .accessibilityIdentifier("listen.voice")
        .accessibilityLabel("Voice")
        .help(narration.voiceName.map { "Voice — \($0)" } ?? "Voice")
    }

    /// Why Readr Voice is missing from the list. On a Mac it is the OS gate
    /// around Apple's BNNS crash; on an iPhone or iPad the MLX runtime needs
    /// a Metal GPU (never missing on a device, always on the simulator).
    private var readrVoiceUnavailableNote: String {
        #if os(iOS)
        return "Readr Voice isn't available on this device. The Apple voice reads instead."
        #else
        return """
        Readr Voice isn't available on this version of \(osName) — an Apple bug \
        crashes it. The Apple voice reads instead.
        """
        #endif
    }

    private var voiceBinding: Binding<String?> {
        Binding(get: { narration.voiceID }, set: { narration.setVoice($0) })
    }

    /// An informational row inside a menu — where better voices come from, or
    /// that none are installed.
    ///
    /// A disabled Button rather than a bare `Text` because a Button is
    /// unambiguously a menu row on both platforms, where a bare `Text`'s
    /// treatment varies. (This was my first guess at why the UI test couldn't
    /// find this line, and it was wrong — the row was rendering, just below a
    /// voice list long enough to push it off the end of the menu. The row's
    /// POSITION is the fix; the Button is kept because it is the more defined
    /// of the two, not because `Text` was proven broken.)
    private func menuNote(_ text: String) -> some View {
        Button(text) {}
            .disabled(true)
    }

    private var sleepMenu: some View {
        Menu {
            Button("Off") { narration.setSleepTimer(.off) }
            Divider()
            ForEach(SleepTimer.minuteOptions, id: \.self) { minutes in
                Button("\(minutes) min") { narration.setSleepTimer(.after(minutes: minutes)) }
            }
            Button("End of chapter") { narration.setSleepTimer(.endOfChapter) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: narration.sleepMode.isOn ? "moon.fill" : "moon")
                    .font(.system(size: 12))
                if let countdown = sleepCountdown {
                    Text(countdown)
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(narration.sleepMode.isOn ? theme.iris : theme.muted)
        }
        .fixedSize()
        .accessibilityIdentifier("listen.sleep")
        .accessibilityLabel("Sleep timer")
        .help("Sleep timer — \(narration.sleepMode.displayName)")
    }

    /// mm:ss left on a timed sleep; nil for Off and End of chapter.
    private var sleepCountdown: String? {
        guard let remaining = narration.sleepRemaining else { return nil }
        let total = Int(remaining.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var closeButton: some View {
        Button { onClose() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.muted)
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("listen.close")
        .accessibilityLabel("Stop listening")
        .help("Stop listening")
    }
}
