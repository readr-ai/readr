import SwiftUI
import ReadrKit

/// Right-hand reader inspector (⌘⇧N): this book's annotations in reading
/// order, with one-click Markdown export and the Article studio a tap away.
/// This panel is the heart of the wedge over Apple Books — highlights stream
/// in as you make them and are never trapped (docs/DESIGN.md, "Notes panel").
struct NotesPanel: View {
    @EnvironmentObject private var model: AppModel
    let book: Book
    var onJumpHighlight: ((Highlight) -> Void)? = nil
    var onJumpPDF: ((PDFHighlight) -> Void)? = nil

    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    private var annotationCount: Int {
        model.highlights(for: book).count + model.pdfHighlights(for: book).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            NotesHeaderActions(book: book)
            AnnotationListView(
                book: book,
                onJumpHighlight: onJumpHighlight,
                onJumpPDF: onJumpPDF
            )
        }
        .padding([.horizontal, .top], 12)
        .background(theme.background)
    }
}

/// The "Compose article" CTA + Markdown export menu, shared by the Notes panel
/// and the library "Highlights & Notes" review so both surfaces offer the same
/// two exits for annotations. The CTA is the design's ink pill with the ✦ AI
/// glyph; Export stays a quiet hairline-bordered button.
struct NotesHeaderActions: View {
    @EnvironmentObject private var model: AppModel
    let book: Book

    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    @State private var showStudio = false

    /// Nil when the book has no annotations (nothing to export).
    private var markdown: String? {
        model.annotationsMarkdown(for: book)
    }

    private var hasAnnotations: Bool {
        !model.highlights(for: book).isEmpty || !model.pdfHighlights(for: book).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showStudio = true
            } label: {
                HStack(spacing: 7) {
                    Text(AppTheme.aiGlyph)
                    Text("Compose article")
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.background)
                .padding(.vertical, 9)
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity)
                .background(theme.inkColor, in: RoundedRectangle(cornerRadius: 9))
                .opacity(hasAnnotations ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!hasAnnotations)
            .accessibilityIdentifier("notes.createArticle")
            .accessibilityLabel("Create Article")
            .help("Compose an article from these highlights with AI")

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
