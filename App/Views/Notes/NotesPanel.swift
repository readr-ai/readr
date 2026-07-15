import SwiftUI
import ReadrKit

#if canImport(UIKit)
import UIKit
#endif

/// Right-hand reader inspector (⌘⇧N): this book's annotations in reading
/// order, with one-click Markdown export and the Article studio a tap away.
/// This panel is the heart of the wedge over Apple Books — highlights stream
/// in as you make them and are never trapped (docs/DESIGN.md, "Notes panel").
struct NotesPanel: View {
    @EnvironmentObject private var model: AppModel
    let book: Book
    var onJumpHighlight: ((Highlight) -> Void)? = nil
    var onJumpPDF: ((PDFHighlight) -> Void)? = nil
    /// R2: recolor/delete of a PDF highlight routed through the PDF controller
    /// so the live PDFKit overlay is reconciled, not just the store. Nil when
    /// no native PDF surface is mounted (text mode / library review) — the
    /// list then updates the store directly, which is correct with no overlay.
    var onRecolorPDF: ((PDFHighlight, HighlightColor) -> Void)? = nil
    var onDeletePDF: ((PDFHighlight) -> Void)? = nil
    /// Host-provided close action. On iPhone the inspector presents as a
    /// sheet whose only built-in exit is the drag grabber — a visible Done
    /// keeps dismissal discoverable. iPad/macOS side columns hide it (the
    /// toolbar toggle is the idiomatic exit there).
    var onClose: (() -> Void)? = nil

    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    private var annotationCount: Int {
        model.highlights(for: book).count + model.pdfHighlights(for: book).count
    }

    private var showsCloseButton: Bool {
        #if os(iOS)
        return onClose != nil && UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Notes")
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                        .foregroundStyle(theme.inkColor)
                    if annotationCount > 0 {
                        Text(annotationCount == 1 ? "1 annotation" : "\(annotationCount) annotations")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(theme.muted)
                    }
                }
                if showsCloseButton {
                    Spacer()
                    Button("Done") { onClose?() }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.inkColor)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("notes.done")
                }
            }
            NotesHeaderActions(book: book)
            AnnotationListView(
                book: book,
                onJumpHighlight: onJumpHighlight,
                onJumpPDF: onJumpPDF,
                onRecolorPDF: onRecolorPDF,
                onDeletePDF: onDeletePDF
            )
        }
        .padding([.horizontal, .top], 12)
        .background(theme.background)
    }
}

/// The "Create Article" CTA + Markdown export menu, shared by the Notes panel
/// and the library "Highlights & Notes" review so both surfaces offer the same
/// two exits for annotations. R7: composing an article is an AI moment, so the
/// CTA is the design's ONE legit Iris-filled button (✦ glyph on iris); Export
/// stays a quiet hairline-bordered button. The CTA is always enabled — opening
/// the studio with no highlights lands on its own "highlight something first"
/// guidance rather than being a dead, disabled control.
struct NotesHeaderActions: View {
    @EnvironmentObject private var model: AppModel
    let book: Book

    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    @State private var showStudio = false

    /// Nil when the book has no annotations (nothing to export). The Create
    /// Article CTA is always enabled (R7), so this now only gates Export.
    private var markdown: String? {
        model.annotationsMarkdown(for: book)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showStudio = true
            } label: {
                HStack(spacing: 7) {
                    Text(AppTheme.aiGlyph)
                    Text("Create Article")
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 9)
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity)
                .background(theme.iris, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            // R7: always enabled — composing IS an AI moment, and with no
            // highlights the studio shows its own guidance state on tap rather
            // than the CTA being a dead disabled control.
            .accessibilityIdentifier("notes.createArticle")
            .accessibilityLabel("Create Article")
            .help("Create an article from these highlights with AI")

            Menu {
                Button {
                    Pasteboard.copy(markdown ?? "")
                } label: {
                    Label("Copy Markdown", systemImage: "doc.on.doc")
                }
                ShareLink(item: markdown ?? "") {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.muted)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.line, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .disabled(markdown == nil)
            .accessibilityIdentifier("notes.exportMarkdown")
            .help("Export these highlights and notes as Markdown")
        }
        .sheet(isPresented: $showStudio) {
            ArticleStudioView(book: book)
                .environmentObject(model)
        }
    }
}
