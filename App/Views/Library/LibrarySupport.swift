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

/// The Import (+) and AI-provider (gear) toolbar buttons, shared by Home and
/// every grid so import stays one click (or ⌘I) away anywhere in the library.
struct LibraryToolbarItems: ToolbarContent {
    @Binding var isImporting: Bool
    @Binding var showSettings: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showSettings = true
            } label: {
                Label("AI Providers", systemImage: "gearshape")
            }
            .help("AI provider settings")
            // The UI tests tap `buttons["AI providers"]` — keep this label.
            .accessibilityLabel("AI providers")
            .accessibilityIdentifier("library.settings")

            Button {
                isImporting = true
            } label: {
                Label("Import", systemImage: "plus")
            }
            .keyboardShortcut("i", modifiers: .command)
            .help("Import a book (⌘I)")
            .accessibilityLabel("Import book")
            .accessibilityIdentifier("library.import")
        }
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
