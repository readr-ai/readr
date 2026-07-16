import XCTest
@testable import ReadrKit

/// Regression tests for M1 (launch readiness): EPUB zip-bomb / unbounded
/// extraction. Verifies the per-entry, cumulative, and spine-count ceilings
/// and that they equal the documented values.
final class ReviewFixesM1ExtractionCapsTests: XCTestCase {

    // MARK: Named constants match the documented limits

    func testExtractionLimitConstantsMatchDocumentedValues() {
        XCTAssertEqual(EPUBExtractionLimits.perEntryByteCap, 64 * 1024 * 1024)
        XCTAssertEqual(EPUBExtractionLimits.cumulativeByteCap, 512 * 1024 * 1024)
        XCTAssertEqual(EPUBBookParser.maxSpineItems, 2000)
    }

    func testBudgetDefaultsToDocumentedLimits() {
        let budget = EPUBExtractionBudget()
        XCTAssertEqual(budget.perEntryByteCap, 64 * 1024 * 1024)
        XCTAssertEqual(budget.cumulativeByteCap, 512 * 1024 * 1024)
    }

    // MARK: Per-entry cap

    func testOversizedSingleEntryThrows() {
        // Small, cheap-to-run caps so we don't allocate real megabytes.
        let budget = EPUBExtractionBudget(perEntryByteCap: 1024, cumulativeByteCap: 1_000_000)
        let container = InMemoryEPUBContainer(
            entries: ["big.bin": Data(count: 1025)],
            extractionBudget: budget
        )
        XCTAssertThrowsError(try container.data(at: "big.bin")) { error in
            guard case EPUBParseError.entryTooLarge(let path, let limit) = error else {
                return XCTFail("expected entryTooLarge, got \(error)")
            }
            XCTAssertEqual(path, "big.bin")
            XCTAssertEqual(limit, 1024)
        }
    }

    // MARK: Cumulative cap

    func testCumulativeOverflowThrows() {
        // Each entry is under the per-entry cap, but together they exceed the
        // shared cumulative cap.
        let budget = EPUBExtractionBudget(perEntryByteCap: 1024, cumulativeByteCap: 1536)
        let container = InMemoryEPUBContainer(
            entries: ["a.bin": Data(count: 1000), "b.bin": Data(count: 1000)],
            extractionBudget: budget
        )
        XCTAssertNoThrow(try container.data(at: "a.bin"))
        XCTAssertThrowsError(try container.data(at: "b.bin")) { error in
            guard case EPUBParseError.cumulativeSizeExceeded(let limit) = error else {
                return XCTFail("expected cumulativeSizeExceeded, got \(error)")
            }
            XCTAssertEqual(limit, 1536)
        }
    }

    // MARK: Under-cap succeeds

    func testUnderCapEntriesExtractSuccessfully() throws {
        let budget = EPUBExtractionBudget(perEntryByteCap: 1024, cumulativeByteCap: 4096)
        let container = InMemoryEPUBContainer(
            entries: ["a.bin": Data(count: 500), "b.bin": Data(count: 500)],
            extractionBudget: budget
        )
        XCTAssertEqual(try container.data(at: "a.bin").count, 500)
        XCTAssertEqual(try container.data(at: "b.bin").count, 500)
        XCTAssertEqual(budget.cumulativeBytes, 1000)
    }

    // MARK: Spine-count ceiling

    func testSpineOverCeilingThrows() {
        let overflow = EPUBBookParser.maxSpineItems + 1
        var manifest = ""
        var spine = ""
        for i in 0..<overflow {
            manifest += "<item id=\"c\(i)\" href=\"c\(i).xhtml\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"c\(i)\"/>"
        }
        var textEntries: [String: String] = [
            "META-INF/container.xml": """
            <?xml version="1.0"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """,
            "content.opf": """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata/>
              <manifest>\(manifest)</manifest>
              <spine>\(spine)</spine>
            </package>
            """,
        ]
        for i in 0..<overflow {
            textEntries["c\(i).xhtml"] = "<html><body><p>c\(i)</p></body></html>"
        }
        let container = InMemoryEPUBContainer(textEntries: textEntries)
        XCTAssertThrowsError(
            try EPUBBookParser().parse(container: container, fallbackTitle: "fallback")
        ) { error in
            guard case EPUBParseError.tooManySpineItems(let count, let limit) = error else {
                return XCTFail("expected tooManySpineItems, got \(error)")
            }
            XCTAssertEqual(count, overflow)
            XCTAssertEqual(limit, EPUBBookParser.maxSpineItems)
        }
    }

    // MARK: A book at the spine ceiling still parses

    func testSpineAtCeilingParses() throws {
        let count = EPUBBookParser.maxSpineItems
        var manifest = ""
        var spine = ""
        for i in 0..<count {
            manifest += "<item id=\"c\(i)\" href=\"c\(i).xhtml\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"c\(i)\"/>"
        }
        var textEntries: [String: String] = [
            "META-INF/container.xml": """
            <?xml version="1.0"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """,
            "content.opf": """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata/>
              <manifest>\(manifest)</manifest>
              <spine>\(spine)</spine>
            </package>
            """,
        ]
        for i in 0..<count {
            textEntries["c\(i).xhtml"] = "<html><body><p>c\(i)</p></body></html>"
        }
        let container = InMemoryEPUBContainer(textEntries: textEntries)
        let book = try EPUBBookParser().parse(container: container, fallbackTitle: "fallback")
        XCTAssertEqual(book.chapters.count, count)
    }

    // MARK: Parser aborts on cap violations (does not import partially)

    /// A book fixture with `chapters` linear spine documents plus optional
    /// nav/NCX/cover entries, wired through container.xml + content.opf so the
    /// full `EPUBBookParser.parse` path exercises the extraction budget.
    private func bookEntries(chapters: [String: Data]) -> [String: Data] {
        var manifest = ""
        var spine = ""
        for path in chapters.keys.sorted() {
            let id = path.replacingOccurrences(of: ".", with: "_")
            manifest += "<item id=\"\(id)\" href=\"\(path)\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"\(id)\"/>"
        }
        let container = """
        <?xml version="1.0"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata/>
          <manifest>\(manifest)</manifest>
          <spine>\(spine)</spine>
        </package>
        """
        var entries: [String: Data] = [
            "META-INF/container.xml": Data(container.utf8),
            "content.opf": Data(opf.utf8),
        ]
        for (path, data) in chapters { entries[path] = data }
        return entries
    }

    /// A hostile book: one normal chapter plus one chapter whose decompressed
    /// bytes exceed the per-entry cap. The parse must throw (abort), not import
    /// the good chapter and silently drop the over-cap one.
    func testParseThrowsWhenSpineEntryOverPerEntryCap() {
        let good = Data("<html><body><p>Legit chapter with real text.</p></body></html>".utf8)
        let hostile = Data(count: 1025)
        let budget = EPUBExtractionBudget(perEntryByteCap: 1024, cumulativeByteCap: 10_000_000)
        let container = InMemoryEPUBContainer(
            entries: bookEntries(chapters: ["a.xhtml": good, "b.xhtml": hostile]),
            extractionBudget: budget
        )
        XCTAssertThrowsError(
            try EPUBBookParser().parse(container: container, fallbackTitle: "fallback")
        ) { error in
            guard case EPUBParseError.entryTooLarge(let path, let limit) = error else {
                return XCTFail("expected entryTooLarge, got \(error)")
            }
            XCTAssertEqual(path, "b.xhtml")
            XCTAssertEqual(limit, 1024)
        }
    }

    /// Each spine entry is under the per-entry cap, but together they overflow
    /// the cumulative cap. The parse must abort rather than importing the
    /// chapters read before the cumulative ceiling was hit.
    func testParseThrowsWhenCumulativeSizeOverflowsAcrossSpineEntries() {
        let payload = "<html><body><p>" + String(repeating: "x", count: 900) + "</p></body></html>"
        let chapter = Data(payload.utf8)
        let entries = bookEntries(chapters: ["a.xhtml": chapter, "b.xhtml": chapter])
        // Every entry is under the per-entry cap. Size the cumulative cap so it
        // covers all entries except the very last spine chapter, so the parse
        // reads the container/opf/first chapter fine and only overflows on the
        // second — proving the overflow aborts rather than importing partially.
        let allBytes = entries.values.reduce(0) { $0 + $1.count }
        let cumulativeCap = allBytes - chapter.count / 2
        let budget = EPUBExtractionBudget(perEntryByteCap: 4096, cumulativeByteCap: cumulativeCap)
        let container = InMemoryEPUBContainer(entries: entries, extractionBudget: budget)
        XCTAssertThrowsError(
            try EPUBBookParser().parse(container: container, fallbackTitle: "fallback")
        ) { error in
            guard case EPUBParseError.cumulativeSizeExceeded(let limit) = error else {
                return XCTFail("expected cumulativeSizeExceeded, got \(error)")
            }
            XCTAssertEqual(limit, cumulativeCap)
        }
    }

    /// A genuinely missing optional entry (referenced by the spine but absent
    /// from the archive) is still skipped, not treated as a cap violation —
    /// the parse succeeds on the remaining readable chapter.
    func testParseSkipsGenuinelyMissingSpineEntry() throws {
        let good = Data("<html><body><p>Readable chapter body.</p></body></html>".utf8)
        var entries = bookEntries(chapters: ["a.xhtml": good])
        // Declare a second spine item whose bytes are absent from the archive.
        entries["content.opf"] = Data("""
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata/>
          <manifest>
            <item id="a_xhtml" href="a.xhtml" media-type="application/xhtml+xml"/>
            <item id="missing" href="missing.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="a_xhtml"/><itemref idref="missing"/></spine>
        </package>
        """.utf8)
        let container = InMemoryEPUBContainer(entries: entries)
        let book = try EPUBBookParser().parse(container: container, fallbackTitle: "fallback")
        XCTAssertEqual(book.chapters.count, 1)
    }
}
