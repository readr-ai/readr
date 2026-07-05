import SwiftUI
import ReadrKit
import UniformTypeIdentifiers

// Pieces shared by the library shell, Home, and the grids: the drag-and-drop
// payload, importable formats, the reading-progress calculation, the shared
// Import/Settings toolbar, and the grid sort order. Kept together so the three
// screens can't drift apart on behavior the user perceives as "the library".

/// A file dragged in from Finder/Files. Received as an *imported copy* in our
/// own temp directory: drop-provided `URL`s aren't security-scoped on iOS, so
/// reading them directly fails outside the sandbox — and the provider's inbox
/// copy can vanish before an async import runs.
struct DroppedBookFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("readr-drop-\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}

/// Formats Readr can currently import via the file importer.
enum LibraryImport {
    static let types: [UTType] = [
        .plainText, .epub, .pdf,
        UTType("net.daringfireball.markdown") ?? .plainText,
    ]
}

enum LibraryProgress {
    /// Fraction of the book read, from the saved position. Chapters before the
    /// current one count as read; within the current chapter the character
    /// offset adds partial credit — chapter-only granularity showed no bar at
    /// all until chapter two, which made a half-read first chapter look
    /// untouched on Home. Nil when the book was never opened or sits at the
    /// very start, which hides the bar entirely.
    static func fraction(for book: Book, position: ReadingPosition?) -> Double? {
        guard let position, !book.chapters.isEmpty else { return nil }
        let chapterCount = book.chapters.count
        let index = min(max(position.chapterIndex, 0), chapterCount - 1)
        let length = max(book.chapters[index].text.count, 1)
        let within = min(max(Double(position.characterOffset) / Double(length), 0), 1)
        let fraction = (Double(index) + within) / Double(chapterCount)
        guard fraction > 0 else { return nil }
        return min(fraction, 1)
    }
}

/// The Import… and AI-provider (gear) header buttons, shared by Home and every
/// grid so import stays one click (or ⌘I) away anywhere in the library. Lives
/// in each screen's content header row (per the Marginalia design) rather than
/// the system toolbar; the accessibility identifiers/labels are unchanged.
struct LibraryHeaderButtons: View {
    @Binding var isImporting: Bool
    @Binding var showSettings: Bool
    let theme: ReadingTheme

    var body: some View {
        HStack(spacing: 10) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.muted)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("AI provider settings")
            // The UI tests tap `buttons["AI providers"]` — keep this label.
            .accessibilityLabel("AI providers")
            .accessibilityIdentifier("library.settings")

            Button {
                isImporting = true
            } label: {
                Text("Import\u{2026}")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.inkColor)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.elevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.line, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("i", modifiers: .command)
            .help("Import a book (⌘I)")
            .accessibilityLabel("Import book")
            .accessibilityIdentifier("library.import")
        }
    }
}

/// The Marginalia progress mark under every cover: a 2px hairline track with
/// an ink fill at the reading fraction, and an 11px muted caption ("34%",
/// "Not started", or "Finished").
struct LibraryProgressHairline: View {
    /// Fraction read, nil when the book was never opened (see
    /// `LibraryProgress.fraction`).
    let fraction: Double?
    let isFinished: Bool
    let theme: ReadingTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    theme.line
                    theme.inkColor
                        .frame(width: geo.size.width * filledFraction)
                }
            }
            .frame(height: 2)
            .clipShape(Capsule())
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
        }
        .accessibilityHidden(true)
    }

    private var filledFraction: CGFloat {
        if isFinished { return 1 }
        return CGFloat(min(max(fraction ?? 0, 0), 1))
    }

    private var label: String {
        if isFinished { return "Finished" }
        guard let fraction, fraction > 0 else { return "Not started" }
        return "\(Int((min(fraction, 1) * 100).rounded()))%"
    }
}

/// Grid sort order. Persisted by raw value (`AppStorage`) so the choice
/// survives section switches and relaunches.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, author

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return "Recent"
        case .title: return "Title"
        case .author: return "Author"
        }
    }
}
