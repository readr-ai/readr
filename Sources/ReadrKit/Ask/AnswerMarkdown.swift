import Foundation

/// One block of a model answer.
///
/// Models answer in Markdown whether or not you ask them to, and a raw
/// `Text(answer)` shows the punctuation instead of the formatting — asterisks
/// around every bold phrase, `>` in front of every quoted line. Block
/// structure is what a plain string loses, so it is recovered here and the
/// view renders each block in its own style.
///
/// INLINE markup (`**bold**`, `*italic*`, `` `code` ``, `[text](url)`) is left
/// in the strings on purpose: the platform's own `AttributedString(markdown:)`
/// handles it well, and it only handles inline runs, which is exactly the part
/// this parser does not do.
public enum AnswerBlock: Sendable, Hashable {
    /// Body text. Soft-wrapped source lines are already joined.
    case paragraph(String)
    case heading(level: Int, text: String)
    /// A `>` quote. One entry per paragraph inside the quote.
    case quote([String])
    /// A fenced code block, verbatim — no inline parsing inside.
    case code(language: String?, text: String)
    case list(ordered: Bool, items: [Item])
    /// A thematic break (`---`).
    case rule

    public struct Item: Sendable, Hashable {
        /// The bullet or number to draw, already rendered ("•", "3.").
        public var marker: String
        public var text: String

        public init(marker: String, text: String) {
            self.marker = marker
            self.text = text
        }
    }
}

/// Splits a Markdown answer into renderable blocks.
///
/// Deliberately small: it covers the constructs models actually emit in a
/// chat answer, and it is tolerant of PARTIAL input, because it runs on every
/// streamed token — an unterminated code fence or a half-written list must
/// render as the best available guess, never as an error or an empty view.
public enum AnswerMarkdown {

    public static func blocks(from markdown: String) -> [AnswerBlock] {
        var parser = Parser()
        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false
        ) {
            parser.take(String(line))
        }
        return parser.finish()
    }

    // MARK: - Line classification

    /// `#`…`######` followed by a space. Returns the level and the text, with
    /// any closing run of `#` trimmed.
    static func heading(in line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " || rest.isEmpty else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    /// A `>` quote line. Returns the text after the marker (empty for a bare
    /// `>`, which separates paragraphs inside the quote).
    static func quote(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        var rest = Substring(trimmed.dropFirst())
        // Nested `>>` reads as one quote — Readr draws a single rule either way.
        while rest.first == ">" { rest = rest.dropFirst() }
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    /// `-`, `*` or `+` followed by a space.
    static func bulletItem(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, "-*+".contains(marker) else { return nil }
        let rest = trimmed.dropFirst()
        guard rest.first == " " else { return nil }
        return String(rest.drop(while: { $0 == " " }))
    }

    /// `1.` or `1)` followed by a space. Returns the number and the text.
    static func orderedItem(in line: String) -> (number: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
        var rest = trimmed.dropFirst(digits.count)
        guard rest.first == "." || rest.first == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        return (number, String(rest.drop(while: { $0 == " " })))
    }

    /// Three or more `-`, `*` or `_` alone on a line.
    static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first) else {
            return false
        }
        return trimmed.allSatisfy { $0 == first }
    }

    /// A ``` or ~~~ fence. Returns the info string (the language), empty when
    /// the fence carries none.
    static func codeFence(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for fence in ["```", "~~~"] where trimmed.hasPrefix(fence) {
            return String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// A line that continues the list item above it rather than starting
    /// something new: indented, and not itself a marker.
    static func isListContinuation(_ line: String) -> Bool {
        guard line.hasPrefix("  ") || line.hasPrefix("\t") else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return bulletItem(in: line) == nil
            && orderedItem(in: line) == nil
            && quote(in: line) == nil
            && heading(in: line) == nil
    }

    // MARK: - Parser

    private struct Parser {
        private var blocks: [AnswerBlock] = []
        /// Soft-wrapped lines of the paragraph being built.
        private var paragraph: [String] = []
        /// Paragraphs of the quote being built, plus its in-progress lines.
        private var quoteParagraphs: [String] = []
        private var quoteLines: [String] = []
        private var listItems: [AnswerBlock.Item] = []
        private var listIsOrdered = false
        private var codeLines: [String]?
        private var codeLanguage: String?

        mutating func take(_ line: String) {
            // Inside a fence everything is verbatim until the closing fence —
            // a `#` or `-` in a code sample is not a heading or a bullet.
            if codeLines != nil {
                if AnswerMarkdown.codeFence(in: line) != nil {
                    flushCode()
                } else {
                    codeLines?.append(line)
                }
                return
            }

            if let language = AnswerMarkdown.codeFence(in: line) {
                flushText()
                codeLanguage = language.isEmpty ? nil : language
                codeLines = []
                return
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushText()
                return
            }

            if let quoted = AnswerMarkdown.quote(in: line) {
                flushParagraph()
                flushList()
                if quoted.isEmpty {
                    closeQuoteParagraph()
                } else {
                    quoteLines.append(quoted)
                }
                return
            }
            flushQuote()

            if let (level, text) = AnswerMarkdown.heading(in: line) {
                flushText()
                if !text.isEmpty { blocks.append(.heading(level: level, text: text)) }
                return
            }

            if AnswerMarkdown.isRule(line) {
                flushText()
                blocks.append(.rule)
                return
            }

            if let text = AnswerMarkdown.bulletItem(in: line) {
                flushParagraph()
                if !listItems.isEmpty && listIsOrdered { flushList() }
                listIsOrdered = false
                listItems.append(.init(marker: "\u{2022}", text: text))
                return
            }

            if let (number, text) = AnswerMarkdown.orderedItem(in: line) {
                flushParagraph()
                if !listItems.isEmpty && !listIsOrdered { flushList() }
                listIsOrdered = true
                listItems.append(.init(marker: "\(number).", text: text))
                return
            }

            // An indented line under a list item belongs to that item.
            if !listItems.isEmpty, AnswerMarkdown.isListContinuation(line) {
                let text = line.trimmingCharacters(in: .whitespaces)
                listItems[listItems.count - 1].text += " " + text
                return
            }

            flushList()
            paragraph.append(line.trimmingCharacters(in: .whitespaces))
        }

        mutating func finish() -> [AnswerBlock] {
            flushCode()
            flushText()
            return blocks
        }

        // MARK: Flushing

        private mutating func flushText() {
            flushParagraph()
            flushQuote()
            flushList()
        }

        private mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        private mutating func closeQuoteParagraph() {
            guard !quoteLines.isEmpty else { return }
            quoteParagraphs.append(quoteLines.joined(separator: " "))
            quoteLines.removeAll()
        }

        private mutating func flushQuote() {
            closeQuoteParagraph()
            guard !quoteParagraphs.isEmpty else { return }
            blocks.append(.quote(quoteParagraphs))
            quoteParagraphs.removeAll()
        }

        private mutating func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(.list(ordered: listIsOrdered, items: listItems))
            listItems.removeAll()
        }

        /// An unterminated fence still renders as code — the answer is parsed
        /// on every streamed token, so "still arriving" is the normal case.
        private mutating func flushCode() {
            guard let lines = codeLines else { return }
            codeLines = nil
            let language = codeLanguage
            codeLanguage = nil
            let text = lines.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            blocks.append(.code(language: language, text: text))
        }
    }
}
