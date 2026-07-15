import SwiftUI
import ReadrKit

/// The annotation popover content, Marginalia style: four muted color dots
/// that highlight in ONE click, then `Note` and `✦ Ask` as quiet text
/// buttons (the ✦ iris mark is reserved for AI). Shared by the text reader
/// (NSPopover/iOS bar) and the native PDF reader — keep it
/// presentation-agnostic: no dismissal logic here, hosts dismiss in the
/// callbacks.
struct AnnotationMenuView: View {
    enum Mode: Equatable {
        /// A fresh selection: color click creates the highlight.
        case create
        /// An existing highlight: color click recolors it.
        case edit(currentColor: HighlightColor, hasNote: Bool)
    }

    let mode: Mode
    /// Reading theme of the hosting surface, so the menu matches the page.
    var theme: ReadingTheme = .paper
    /// Create (or recolor) the highlight with this color.
    var onHighlight: (HighlightColor) -> Void
    /// Open the note editor (creates the highlight first when in create mode).
    var onNote: () -> Void
    /// Ask the book about this selection.
    var onAsk: () -> Void
    var onCopy: () -> Void
    /// Only shown in edit mode.
    var onRemove: (() -> Void)?

    /// The keyboard shortcuts act on the live text selection, so their hints
    /// are only truthful in create mode — an edit menu (clicked highlight,
    /// no selection) must not advertise keys that would no-op there.
    private var isCreate: Bool { mode == .create }

    /// Create mode advertises ⇧⌘M; edit mode names the action plainly.
    private var noteHelp: String {
        if mode.hasNote { return "Edit note" }
        return isCreate ? "Add a note (⇧⌘M)" : "Add a note"
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ReadingTheme.pickerColors, id: \.self) { color in
                colorDot(color)
            }
            if case .edit = mode, let onRemove {
                Button(action: onRemove) {
                    Text("✕").font(.system(size: 12)).annotationTouchTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.faint)
                .help("Remove highlight")
                .accessibilityLabel("Remove highlight")
                .accessibilityIdentifier("annotation.remove")
            }

            Rectangle()
                .fill(theme.line)
                .frame(width: 1, height: 16)

            Button(action: onNote) {
                Text(mode.hasNote ? "Edit Note" : "Note")
                    .font(.system(size: 12, weight: .medium))
                    .annotationTouchTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.inkColor)
            .help(noteHelp)
            .accessibilityLabel(mode.hasNote ? "Edit Note" : "Note")
            .accessibilityIdentifier("annotation.note")

            Button(action: onAsk) {
                Text("\(AppTheme.aiGlyph) Ask")
                    .font(.system(size: 12, weight: .semibold))
                    .annotationTouchTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.iris)
            .help(isCreate
                ? "Ask the book about this passage (⇧⌘A)"
                : "Ask the book about this passage")
            .accessibilityLabel("Ask")
            .accessibilityIdentifier("annotation.ask")

            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .annotationTouchTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.muted)
            .help("Copy")
            .accessibilityLabel("Copy")
            .accessibilityIdentifier("annotation.copy")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.elevated)
    }

    private func colorDot(_ color: HighlightColor) -> some View {
        Button {
            onHighlight(color)
        } label: {
            ZStack {
                Circle()
                    .fill(ReadingTheme.markerSwatch(color))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
                    .frame(width: 19, height: 19)
                if case let .edit(current, _) = mode, current == color {
                    Circle()
                        .strokeBorder(theme.inkColor.opacity(0.65), lineWidth: 1.5)
                        .frame(width: 25, height: 25)
                }
            }
            // R5: keep the 25pt visual dot but grow the tappable area to
            // ≥44×44 on touch (Apple HIG); macOS keeps the compact target.
            .frame(width: 25, height: 25)
            .annotationTouchTarget()
        }
        .buttonStyle(.plain)
        .help(isCreate
            ? "Highlight \(color.displayName) (⇧⌘H uses the last-used color)"
            : "Highlight \(color.displayName)")
        .accessibilityLabel("Highlight \(color.displayName)")
        .accessibilityIdentifier("annotation.color.\(color.rawValue)")
    }
}

private extension AnnotationMenuView.Mode {
    var hasNote: Bool {
        if case let .edit(_, hasNote) = self { return hasNote }
        return false
    }
}
