#if os(macOS)
import AppKit
import XCTest
@testable import Readr

final class ReaderWindowConfigurationTests: XCTestCase {
    func testReaderWindowIsResizableAndFullScreenCapable() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        WindowFrameFitter.configureReader(window)

        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertEqual(window.contentMinSize, ReaderWindowSizing.minimumContentSize)
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isEnabled, true)
    }

    func testTrackpadSwipeTurnsOncePerHorizontalGesture() {
        var detector = MacTrackpadPageTurnDetector()
        detector.beginGesture()

        XCTAssertNil(detector.add(horizontal: -18, vertical: 3))
        XCTAssertEqual(detector.add(horizontal: -22, vertical: 2), 1)
        XCTAssertNil(detector.add(horizontal: -80, vertical: 0))

        detector.endGesture()
        detector.beginGesture()
        XCTAssertEqual(detector.add(horizontal: 40, vertical: 4), -1)
    }

    func testTrackpadVerticalScrollDoesNotTurnPage() {
        var detector = MacTrackpadPageTurnDetector()
        detector.beginGesture()

        XCTAssertNil(detector.add(horizontal: 20, vertical: 50))
        XCTAssertNil(detector.add(horizontal: 20, vertical: 50))
    }
}
#endif
