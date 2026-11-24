import XCTest

/// Open the seeded "Field Notes" PDF from Home and wait for the native PDFKit
/// reader, asserted via its page indicator.
///
/// One copy for every suite (the flow tests' PDF cases and the Listen tests'
/// PDF case): the card is a button labeled by title whose title also surfaces
/// as a static text, it sits in Home's Recently Added row (below the fold on
/// a small phone), and PDFKit reports its page count asynchronously.
func openFieldNotesPDF(
    _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
) {
    let pdfButton = app.buttons["Field Notes"].firstMatch
    let pdfCard = pdfButton.waitForExistence(timeout: 10)
        ? pdfButton
        : app.staticTexts["Field Notes"].firstMatch
    XCTAssertTrue(
        pdfCard.waitForExistence(timeout: 5), "The seeded PDF should be on the shelf",
        file: file, line: line
    )
    if !pdfCard.isHittable { app.swipeUp() }
    pdfCard.tap()
    XCTAssertTrue(
        app.staticTexts["pdf.pageIndicator"].firstMatch.waitForExistence(timeout: 15),
        "The PDF reader should show its page indicator",
        file: file, line: line
    )
}

/// Page the seeded two-page PDF to its second page and wait for PDFKit to say
/// so. PDFKit updates the current page after its scroll settles, so each
/// swipe is followed by a short predicate wait rather than an immediate read.
/// Fails (never skips) when the second page cannot be reached: a test that
/// depends on being on page 2 must not go green by not getting there.
func pageSeededPDFToPageTwo(
    _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
) {
    let indicator = app.staticTexts["pdf.pageIndicator"].firstMatch
    let onPageTwo = NSPredicate(format: "label BEGINSWITH 'Page 2 of 2'")
    let swipes: [() -> Void] = [{ app.swipeUp() }, { app.swipeLeft() }, { app.swipeUp() }]
    for swipe in swipes {
        swipe()
        let settled = XCTNSPredicateExpectation(predicate: onPageTwo, object: indicator)
        if XCTWaiter().wait(for: [settled], timeout: 3) == .completed { return }
    }
    XCTFail("Could not page the seeded PDF to page 2 (indicator: \(indicator.label))", file: file, line: line)
}
