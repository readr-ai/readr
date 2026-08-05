import XCTest
@testable import ReadrKit

/// Adding a span kind must never cost a reader their library (PR #65 review).
///
/// Swift synthesizes enum `Codable` as a single-key object named after the
/// case, and decoding refuses any key it doesn't know. `FileLibraryStore`
/// decodes the whole state with `try?` and treats failure as corruption: it
/// moves `library.json` aside and starts empty. So a build that predates a
/// span kind cannot read a library written by one that has it — a tester
/// rolling back a TestFlight build would lose every book, position, highlight
/// and bookmark.
///
/// Colour spans are therefore persisted under a separate optional key. Unknown
/// keys are ignored by `Codable`, which is how every other field added to this
/// model stayed safe.
final class SpanPersistenceCompatibilityTests: XCTestCase {

    /// A stand-in for the span vocabulary as it shipped before this change.
    private struct LegacyChapter: Codable {
        struct LegacySpan: Codable {
            enum LegacyKind: Hashable, Codable {
                case heading(Int)
                case bold, italic, blockquote
                case link(LinkTarget)
                case superscript
                case `subscript`
                case alignment(TextAlignment)
                case smallCaps
            }
            var start: Int
            var end: Int
            var kind: LegacyKind
        }
        var id: UUID
        var title: String?
        var order: Int
        var text: String
        var formatSpans: [LegacySpan]?
    }

    private func chapterWithColours() -> Chapter {
        Chapter(
            title: "One",
            order: 0,
            text: "Some prose with a highlight in it.",
            formatSpans: [
                FormatSpan(start: 0, end: 4, kind: .bold),
                FormatSpan(
                    start: 5, end: 10,
                    kind: .highlighted(CSSColor(red: 1, green: 1, blue: 0))
                ),
                FormatSpan(
                    start: 11, end: 15,
                    kind: .colored(CSSColor(red: 0.5, green: 0, blue: 0))
                ),
                FormatSpan(start: 16, end: 20, kind: .italic),
            ]
        )
    }

    /// The regression itself: a build without the colour cases must still
    /// decode a chapter written by one that has it.
    func testAPreviousBuildCanStillDecodeAChapterWithColourSpans() throws {
        let data = try JSONEncoder().encode(chapterWithColours())
        let legacy = try JSONDecoder().decode(LegacyChapter.self, from: data)

        XCTAssertEqual(legacy.text, "Some prose with a highlight in it.")
        XCTAssertEqual(
            legacy.formatSpans?.count, 2,
            "the old build keeps the kinds it understands and ignores the rest"
        )
        XCTAssertEqual(legacy.formatSpans?.map(\.kind), [.bold, .italic])
    }

    /// And the colours are not lost — this build round-trips all four.
    func testColourSpansSurviveARoundTripInThisBuild() throws {
        let data = try JSONEncoder().encode(chapterWithColours())
        let restored = try JSONDecoder().decode(Chapter.self, from: data)

        XCTAssertEqual(restored.formatSpans?.count, 4)
        XCTAssertTrue(
            restored.formatSpans?.contains {
                if case .highlighted = $0.kind { return true }
                return false
            } == true
        )
        XCTAssertTrue(
            restored.formatSpans?.contains {
                if case .colored = $0.kind { return true }
                return false
            } == true
        )
    }

    /// The colours must actually live under their own key, not in the array a
    /// previous build reads.
    func testColourSpansArePersistedUnderTheirOwnKey() throws {
        let data = try JSONEncoder().encode(chapterWithColours())
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual((json["formatSpans"] as? [Any])?.count, 2)
        XCTAssertEqual((json["colorSpans"] as? [Any])?.count, 2)
    }

    /// A chapter with no colours must not gain an empty key, so libraries that
    /// never see a coloured book are byte-for-byte as before.
    func testAChapterWithoutColoursWritesNoColourKey() throws {
        let plain = Chapter(
            title: "One", order: 0, text: "Plain.",
            formatSpans: [FormatSpan(start: 0, end: 5, kind: .bold)]
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plain))
                as? [String: Any]
        )
        XCTAssertNil(json["colorSpans"])
        XCTAssertNotNil(json["formatSpans"])
    }

    /// Everything else on the chapter has to survive the hand-written coder —
    /// the risk of replacing a synthesized conformance is a silently dropped
    /// field.
    func testHandWrittenCoderPreservesEveryField() throws {
        let chapter = Chapter(
            title: "Loomings",
            order: 3,
            text: "Call me Ishmael.\u{FFFC}",
            images: [ChapterImage(offset: 16, archivePath: "OEBPS/whale.jpg")],
            formatSpans: [FormatSpan(start: 0, end: 4, kind: .bold)],
            sourcePath: "OEBPS/ch1.xhtml",
            anchors: ["note3": 12],
            footnotes: [Footnote(id: "note3", text: "A note.")],
            isLinear: false
        )
        let restored = try JSONDecoder().decode(
            Chapter.self, from: JSONEncoder().encode(chapter)
        )
        XCTAssertEqual(restored, chapter)
    }

    /// Footnote bodies carry spans too, and got the same split.
    func testFootnoteColourSpansRoundTripAndStaySeparate() throws {
        let note = Footnote(
            id: "n1", text: "A coloured note.",
            formatSpans: [
                FormatSpan(start: 0, end: 1, kind: .italic),
                FormatSpan(
                    start: 2, end: 5,
                    kind: .highlighted(CSSColor(red: 1, green: 1, blue: 0))
                ),
            ]
        )
        let data = try JSONEncoder().encode(note)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual((json["formatSpans"] as? [Any])?.count, 1)
        XCTAssertEqual((json["colorSpans"] as? [Any])?.count, 1)

        let restored = try JSONDecoder().decode(Footnote.self, from: data)
        XCTAssertEqual(restored.formatSpans?.count, 2)
    }

    /// Forward compatibility, the other direction: a *future* build may add a
    /// span kind this one has never seen. Losing those colours must not cost
    /// the reader the chapter.
    func testAnUndecodableColourSpanDoesNotSinkTheChapter() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "title": "One",
          "order": 0,
          "text": "Some prose.",
          "formatSpans": [{"start": 0, "end": 4, "kind": {"bold": {}}}],
          "colorSpans": [{"start": 5, "end": 9, "kind": {"iridescent": {"_0": 1}}}]
        }
        """
        let chapter = try JSONDecoder().decode(
            Chapter.self, from: Data(json.utf8)
        )
        XCTAssertEqual(chapter.text, "Some prose.")
        XCTAssertEqual(chapter.formatSpans?.count, 1, "the known span survives")
    }

    /// A library written before this change has no colour key at all.
    func testAChapterWrittenByAPreviousBuildStillDecodes() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "title": "One",
          "order": 0,
          "text": "Older prose.",
          "formatSpans": [{"start": 0, "end": 5, "kind": {"italic": {}}}]
        }
        """
        let chapter = try JSONDecoder().decode(Chapter.self, from: Data(json.utf8))
        XCTAssertEqual(chapter.formatSpans?.count, 1)
        XCTAssertEqual(chapter.formatSpans?.first?.kind, .italic)
    }
}
