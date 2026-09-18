import SwiftUI
import ReadrKit

/// Renders a model answer as formatted text rather than as the Markdown
/// punctuation the model wrote.
///
/// A plain `Text(answer)` put `**the words you use**` and `> "What is a
/// depressed mood, exactly?"` on screen verbatim. Block structure comes from
/// `AnswerMarkdown` (ReadrKit, tested); inline runs come from the platform's
/// own Markdown parser, which is good at exactly the part `AnswerMarkdown`
/// leaves alone.
///
/// It re-parses on every streamed token by design: the parser is tolerant of
/// half-written input, so a partial answer formats as far as it has arrived
/// instead of flickering between raw and rendered.
struct AnswerMarkdownView: View {
    let markdown: String
    let theme: ReadingTheme

    @AppStorage(AskPreferences.answerFontSizeKey)
    private var storedFontSize = AskPreferences.defaultAnswerFontSize
    /// Preserve Dynamic Type on top of the reader's chosen base size.
    @ScaledMetric(relativeTo: .callout) private var dynamicTypeScale: CGFloat = 1

    private var bodyFontSize: CGFloat {
        CGFloat(AskPreferences.clampedAnswerFontSize(storedFontSize)) * dynamicTypeScale
    }

    private func fontSize(offset: CGFloat = 0) -> CGFloat {
        max(10, bodyFontSize + offset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(AnswerMarkdown.blocks(from: markdown).enumerated()), id: \.offset) {
                _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: AnswerBlock) -> some View {
        switch block {
        case let .paragraph(text):
            Text(AnswerMarkdownView.inline(text))
                .font(.system(size: fontSize()))
                .lineSpacing(6)
                .foregroundStyle(theme.inkColor)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .heading(level, text):
            // The chosen base size is still multiplied by Dynamic Type.
            Text(AnswerMarkdownView.inline(text))
                .font(.system(
                    size: fontSize(offset: level <= 2 ? 1 : -1),
                    weight: .semibold,
                    design: .serif
                ))
                .foregroundStyle(theme.inkColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)

        case let .quote(paragraphs):
            // The same iris-ruled quote the panel uses for the reader's own
            // selection, so a passage the model quotes reads as the book's
            // voice rather than the model's.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(AnswerMarkdownView.inline(paragraph))
                        .font(.system(size: fontSize(offset: -1), design: .serif))
                        .italic()
                        .lineSpacing(4)
                        .foregroundStyle(theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(theme.iris).frame(width: 2)
            }

        case let .code(_, text):
            // Code must not reflow, so it scrolls sideways rather than
            // wrapping mid-token.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: fontSize(offset: -2), design: .monospaced))
                    .foregroundStyle(theme.inkColor)
                    .padding(10)
            }
            .background(theme.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))

        case let .list(_, items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(.system(size: fontSize()))
                            .foregroundStyle(theme.faint)
                            // Numbers and bullets line up in one gutter.
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(AnswerMarkdownView.inline(item.text))
                            .font(.system(size: fontSize()))
                            .lineSpacing(5)
                            .foregroundStyle(theme.inkColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .rule:
            theme.line
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    /// Inline Markdown (`**bold**`, `*italic*`, `` `code` ``, links) via the
    /// platform parser.
    ///
    /// `.inlineOnlyPreservingWhitespace` is the right mode precisely because
    /// block structure has already been handled: full parsing would flatten
    /// the blocks back into one run and drop the newlines. A partially
    /// streamed run (`**the words`) has no closing marker yet, so the parser
    /// leaves it as literal text and it resolves itself as more arrives.
    static func inline(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }
}
