import SwiftUI
import ReadrKit

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
                sentenceLine
                Spacer(minLength: 8)
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
            Button { narration.togglePlayPause() } label: {
                Image(systemName: narration.isSpeaking ? "pause.fill" : "play.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.inkColor)
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("listen.playPause")
            .accessibilityLabel(narration.isSpeaking ? "Pause" : "Play")
            .help(narration.isSpeaking ? "Pause narration" : "Play narration")
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

    // MARK: - Read-along line

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
            // Above the list, not below it: the voice list is as long as the
            // reader has voices installed, and anything under it is off the
            // bottom of the menu — unreachable, and never even rendered.
            menuNote("More voices: Settings \u{203A} Accessibility \u{203A} Spoken Content")
            // The Readr Voice model is a one-time ~104MB download; narration
            // reads through the platform voice meanwhile and switches at a
            // sentence boundary. Said here so the wait is never a mystery —
            // but only while Readr Voice is actually the selected narrator:
            // a reader who picked a platform voice mid-download must not be
            // promised a switch the router will never perform.
            if KokoroSpeechEngine.isKokoroVoiceID(narration.voiceID) {
                switch narration.readrVoiceReadiness {
                case .downloading:
                    menuNote("Readr Voice is downloading \u{2014} switching automatically when ready")
                case .failed:
                    menuNote("Readr Voice couldn't download \u{2014} pick it again to retry")
                case .notReady, .ready:
                    EmptyView()
                }
            }
            Divider()
            if narration.voices.isEmpty {
                menuNote("No voices installed")
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
