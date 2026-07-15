import SwiftUI
import ReadrKit

/// The note editor, Marginalia style: a compact elevated card — caps "NOTE"
/// label, the quoted passage with a muted left rule, a paper text field, and
/// right-aligned Cancel / ink-filled Save. Creation of the highlight happens
/// before this opens — the editor only writes the note text back via `onSave`.
struct NoteEditor: View {
    /// The highlighted passage shown above the editor for context.
    let quotedText: String
    @Binding var text: String
    var onSave: () -> Void
    /// Runs when Cancel is pressed. Create-mode hosts pass a closure that
    /// removes the highlight they just created for this note — otherwise a
    /// cancelled note strands a highlight the reader never asked to keep.
    /// Nil for plain edits of an existing highlight's note.
    var onCancel: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    /// Matches the reader's persisted theme so the card sits on the same
    /// palette as the page it annotates (shared with the PDF reader host).
    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NOTE")
                .font(.system(size: 10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(theme.faint)

            if !quotedText.isEmpty {
                Text("\u{201C}\(quotedText)\u{201D}")
                    .font(.system(size: 12, design: .serif))
                    .italic()
                    .foregroundStyle(theme.muted)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        // R6/D1: the quoted-passage rule is generic chrome (the
                        // user's own highlight, not an AI citation) — neutral
                        // muted, keeping Iris reserved for AI moments.
                        Rectangle().fill(theme.muted).frame(width: 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextEditor(text: $text)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.inkColor)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 88, maxHeight: 160)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { onCancel?(); dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel")

                Button { onSave(); dismiss() } label: {
                    Text("Save")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.background)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.inkColor))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Save")
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(theme.elevated)
        .presentationBackground(theme.elevated)
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }
}
