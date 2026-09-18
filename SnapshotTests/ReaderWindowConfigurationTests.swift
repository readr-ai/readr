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
}
#endif
