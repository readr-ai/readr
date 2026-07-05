import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A read-only, selectable text view that reports the selected **character**
/// range and paints existing highlights. Wraps `UITextView` (iOS) / `NSTextView`
/// (macOS) because SwiftUI's `Text` does not expose selection ranges to code —
/// which we need for highlight capture (J3). Renders with the app's
/// `ReaderStyle` (theme ink, serif type, line spacing).
struct SelectableTextView: View {
    let text: String
    /// Character ranges to paint as highlights.
    let highlightRanges: [Range<Int>]
    var style = ReaderStyle()
    /// Inline images keyed by the character offset of their U+FFFC placeholder
    /// in `text`.
    var inlineImages: [Int: PlatformImage] = [:]
    /// Called with the selected character range (empty selection ⇒ not called).
    let onSelect: (Range<Int>) -> Void

    var body: some View {
        Representable(
            text: text,
            highlightRanges: highlightRanges,
            style: style,
            inlineImages: inlineImages,
            onSelect: onSelect
        )
    }
}

// MARK: - Range conversion helpers

enum TextRangeConvert {
    /// Platform NSRange (UTF-16) → character-offset range into `text`.
    static func characterRange(from nsRange: NSRange, in text: String) -> Range<Int>? {
        guard nsRange.length > 0, let r = Range(nsRange, in: text) else { return nil }
        let lower = text.distance(from: text.startIndex, to: r.lowerBound)
        let upper = text.distance(from: text.startIndex, to: r.upperBound)
        return lower..<upper
    }

    /// Character-offset range → NSRange (UTF-16) for attributing the string.
    static func nsRange(from range: Range<Int>, in text: String) -> NSRange? {
        guard let lower = text.index(text.startIndex, offsetBy: range.lowerBound, limitedBy: text.endIndex),
              let upper = text.index(text.startIndex, offsetBy: range.upperBound, limitedBy: text.endIndex)
        else { return nil }
        return NSRange(lower..<upper, in: text)
    }

    static func attributedString(
        _ text: String,
        highlightRanges: [Range<Int>],
        style: ReaderStyle,
        inlineImages: [Int: PlatformImage] = [:]
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)
        let full = NSRange(text.startIndex..<text.endIndex, in: text)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        paragraph.paragraphSpacing = style.fontSize * 0.6

        attributed.addAttribute(.font, value: style.contentFont, range: full)
        attributed.addAttribute(.foregroundColor, value: style.theme.ink, range: full)
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: full)

        for range in highlightRanges {
            if let ns = nsRange(from: range, in: text) {
                attributed.addAttribute(.backgroundColor, value: style.theme.highlight, range: ns)
            }
        }

        for (offset, image) in inlineImages.sorted(by: { $0.key < $1.key }) {
            guard let ns = nsRange(from: offset..<(offset + 1), in: text),
                  let placeholder = Range(ns, in: text),
                  text[placeholder] == "\u{FFFC}"
            else { continue }
            let attachment = NSTextAttachment()
            attachment.image = image
            let size = image.size
            if size.width > 0, size.height > 0 {
                // Cap width so oversized figures don't blow out the column;
                // preserve the aspect ratio.
                let maxWidth: CGFloat = 500
                let width = min(maxWidth, size.width)
                let height = width * size.height / size.width
                attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            }
            attributed.addAttribute(.attachment, value: attachment, range: ns)
        }
        return attributed
    }
}

// MARK: - Platform representable

#if canImport(UIKit)
private struct Representable: UIViewRepresentable {
    let text: String
    let highlightRanges: [Range<Int>]
    let style: ReaderStyle
    let inlineImages: [Int: PlatformImage]
    let onSelect: (Range<Int>) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        view.textContainerInset = .zero
        view.adjustsFontForContentSizeCategory = true
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.text = text
        // Only rebuild the attributed string when the content actually changed —
        // reassigning it resets the user's selection and re-fires the delegate.
        guard context.coordinator.needsRender(
            text: text, ranges: highlightRanges, style: style,
            imageOffsets: inlineImages.keys.sorted()
        ) else { return }
        view.attributedText = TextRangeConvert.attributedString(
            text, highlightRanges: highlightRanges, style: style, inlineImages: inlineImages
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: text, onSelect: onSelect) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: String
        var onSelect: (Range<Int>) -> Void
        private var renderedText: String?
        private var renderedRanges: [Range<Int>] = []
        private var renderedStyle: ReaderStyle?
        private var renderedImageOffsets: [Int] = []
        init(text: String, onSelect: @escaping (Range<Int>) -> Void) {
            self.text = text; self.onSelect = onSelect
        }
        func needsRender(text: String, ranges: [Range<Int>], style: ReaderStyle, imageOffsets: [Int]) -> Bool {
            guard renderedText == text, renderedRanges == ranges, renderedStyle == style,
                  renderedImageOffsets == imageOffsets else {
                renderedText = text; renderedRanges = ranges; renderedStyle = style
                renderedImageOffsets = imageOffsets
                return true
            }
            return false
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            if let range = TextRangeConvert.characterRange(from: textView.selectedRange, in: text) {
                onSelect(range)
            }
        }
    }
}
#elseif canImport(AppKit)
private struct Representable: NSViewRepresentable {
    let text: String
    let highlightRanges: [Range<Int>]
    let style: ReaderStyle
    let inlineImages: [Int: PlatformImage]
    let onSelect: (Range<Int>) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        scroll.drawsBackground = false
        textView.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.onSelect = onSelect
        context.coordinator.text = text
        guard context.coordinator.needsRender(
            text: text, ranges: highlightRanges, style: style,
            imageOffsets: inlineImages.keys.sorted()
        ) else { return }
        textView.textStorage?.setAttributedString(
            TextRangeConvert.attributedString(
                text, highlightRanges: highlightRanges, style: style, inlineImages: inlineImages
            )
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: text, onSelect: onSelect) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: String
        var onSelect: (Range<Int>) -> Void
        private var renderedText: String?
        private var renderedRanges: [Range<Int>] = []
        private var renderedStyle: ReaderStyle?
        private var renderedImageOffsets: [Int] = []
        init(text: String, onSelect: @escaping (Range<Int>) -> Void) {
            self.text = text; self.onSelect = onSelect
        }
        func needsRender(text: String, ranges: [Range<Int>], style: ReaderStyle, imageOffsets: [Int]) -> Bool {
            guard renderedText == text, renderedRanges == ranges, renderedStyle == style,
                  renderedImageOffsets == imageOffsets else {
                renderedText = text; renderedRanges = ranges; renderedStyle = style
                renderedImageOffsets = imageOffsets
                return true
            }
            return false
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if let range = TextRangeConvert.characterRange(from: textView.selectedRange(), in: text) {
                onSelect(range)
            }
        }
    }
}
#endif
