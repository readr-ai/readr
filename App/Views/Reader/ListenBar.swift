import SwiftUI
import ReadrKit
#if os(iOS)
import UIKit
#endif

/// The now-reading card: what the reader sees while the book is read aloud.
///
/// One card, insetting the page from the bottom rather than floating over
/// it (the page turns itself to follow the voice, so nothing may cover the
/// words): the chapter in caps, the sentence being read, a hairline of the
/// chapter's progress, and one row of controls — speed on the left, ◀ ● ▶
/// in the middle, the sleep timer on the right, ✕ in the corner. That is
/// the whole of it. The voice is chosen in the Aa popover (once, not per
/// listen); chapter skips live in Contents; and the "N min ready" figure
/// is gone — the buffer's state shows only when it matters: preparing, or
/// failed. (September 2026 UX review, F6, Option B.)
///
/// Styling follows the reading theme, so switching to Dark doesn't leave a
/// bright slab at the bottom of the page.
struct ListenBar: View {
    @ObservedObject var narration: NarrationModel
    let style: ReaderStyle
    /// The chapter the voice is in, for the card's kicker.
    var chapterTitle: String? = nil
    /// The reading surface behind the card, so its margins are the page.
    var surface: Color? = nil
    /// Close the card and end narration.
    let onClose: () -> Void

    private var theme: ReadingTheme { style.theme }

    var body: some View {
        card
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .background(surface ?? theme.paper)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("listen.bar")
            .accessibilityLabel("Narration controls")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    if let chapterTitle, !chapterTitle.isEmpty {
                        Text(chapterTitle.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(1.5)
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                    statusLine
                }
                Spacer(minLength: 8)
                closeButton
            }
            progressTrack
                .padding(.top, 10)
                .padding(.bottom, 2)
            HStack(alignment: .center, spacing: 0) {
                speedMenu
                Spacer(minLength: 0)
                transportControls
                Spacer(minLength: 0)
                sleepMenu
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .background(theme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }

    // MARK: - Transport

    private var transportControls: some View {
        HStack(spacing: 6) {
            control(
                "backward.fill", id: "listen.previous", label: "Previous sentence",
                help: "Previous sentence"
            ) { narration.skipBackward() }
            // Preparing shows Pause too: the voice is on its way and the
            // control pauses the wait, the way it pauses speech.
            Button { narration.togglePlayPause() } label: {
                Image(systemName: narration.isUnderway ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.background)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(theme.inkColor))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .accessibilityIdentifier("listen.playPause")
            .accessibilityLabel(narration.isUnderway ? "Pause" : "Play")
            .help(narration.isUnderway ? "Pause narration" : "Play narration")
            control(
                "forward.fill", id: "listen.next", label: "Next sentence",
                help: "Next sentence"
            ) { narration.skipForward() }
        }
    }

    private func control(
        _ symbol: String, id: String, label: String, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(theme.inkColor)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
        .help(help)
    }

    // MARK: - Status line

    /// What the card says under the kicker: the wait for the Readr Voice
    /// model, a failed download with its Retry, a hold, or — nearly always
    /// — the sentence being read.
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

    /// The sentence being spoken. The page follows the voice on its own, so
    /// this is a confirmation of *where* rather than the only way to tell.
    private var sentenceLine: some View {
        Text(narration.currentSentence)
            .font(.system(size: 14, design: .serif))
            .italic()
            .foregroundStyle(theme.inkColor)
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("listen.sentence")
            .accessibilityLabel("Now reading: \(narration.currentSentence)")
    }

    /// Narration paused on its own — with the screen locked, nothing was
    /// ready for the next sentence. Unlocking resumes it; this is for the
    /// reader who has just done that and wants to know why it stopped.
    private func holdLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(theme.muted)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("listen.hold")
            .accessibilityLabel(text)
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
                .font(.system(size: 13))
                .foregroundStyle(theme.muted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    /// voice is a pick away in the Aa popover, never automatic.
    private var failedLine: some View {
        HStack(spacing: 8) {
            Text("Readr Voice couldn\u{2019}t download.")
                .font(.system(size: 13))
                .foregroundStyle(theme.muted)
                .lineLimit(2)
            Button("Retry") { narration.retryReadrVoice() }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.iris)
                .buttonStyle(.plain)
                .accessibilityIdentifier("listen.retry")
                .accessibilityLabel("Retry the Readr Voice download")
                .help("Download Readr Voice again and keep listening")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("listen.failed")
    }

    private var progressTrack: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.line)
                Capsule()
                    .fill(theme.iris)
                    .frame(width: geometry.size.width * min(max(narration.chapterProgress, 0), 1))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }

    // MARK: - Speed and sleep

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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.inkColor)
                .monospacedDigit()
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier("listen.speed")
        .accessibilityLabel("Speaking speed")
        .help("Speaking speed")
    }

    private var speedBinding: Binding<Double> {
        Binding(get: { narration.rate }, set: { narration.setRate($0) })
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
            HStack(spacing: 5) {
                Image(systemName: narration.sleepMode.isOn ? "moon.fill" : "moon")
                    .font(.system(size: 12))
                Text(sleepCountdown ?? "Sleep")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(narration.sleepMode.isOn ? theme.iris : theme.inkColor)
            .frame(minHeight: 44)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
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
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, -6)
        .padding(.trailing, -8)
        .accessibilityIdentifier("listen.close")
        .accessibilityLabel("Stop listening")
        .help("Stop listening — your place is kept")
    }
}

// MARK: - Voice picker (Aa popover)

/// The narrator, chosen once in the Aa popover rather than on every Listen
/// bar: Readr Voice (checked) with the Apple voices behind a disclosure for
/// an English book, the Apple voices for the book's language otherwise,
/// and the notes that used to ride the bar's menu.
struct NarrationVoicePicker: View {
    @ObservedObject var narration: NarrationModel
    let theme: ReadingTheme

    private var osName: String {
        #if os(iOS)
        UIDevice.current.systemName
        #else
        "macOS"
        #endif
    }

    var body: some View {
        Menu {
            // Notes go above the list, not below it: the voice list is as
            // long as the reader has voices installed, and anything under it
            // is off the bottom of the menu.
            menuNote("More voices: Settings \u{203A} Accessibility \u{203A} Spoken Content")
            if narration.readrVoiceFailed {
                menuNote(
                    "Readr Voice couldn\u{2019}t download or stopped responding \u{2014} "
                        + "Retry is on the Listen card"
                )
            }
            if narration.readrVoiceKeepsReadingWhenLocked, narration.usesReadrVoice {
                menuNote("Keeps reading with the screen locked")
            }
            if narration.readrVoiceUnavailable {
                menuNote(readrVoiceUnavailableNote)
            }
            Divider()
            if narration.voices.isEmpty {
                menuNote("No voices installed")
            } else if narration.readrVoiceOffered {
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
            HStack {
                Text(narration.voiceName ?? "Voice")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.inkColor)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
        .help(narration.voiceName.map { "Voice — \($0)" } ?? "Voice")
        .accessibilityLabel("Voice")
        .accessibilityIdentifier("appearance.voice")
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

    /// An informational row inside a menu. A disabled Button rather than a
    /// bare `Text` because a Button is unambiguously a menu row on both
    /// platforms.
    private func menuNote(_ text: String) -> some View {
        Button(text) {}
            .disabled(true)
    }
}
