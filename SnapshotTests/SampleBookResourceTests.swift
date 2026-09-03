import XCTest
@testable import Readr

/// The first-run sample book is a bundled resource, and a resource is only as
/// present as the build rule that copies it. `project.yml` has to tell
/// XcodeGen that `.epub` is data, not source; when that rule breaks, the file
/// silently never reaches the bundle and a fresh install is an empty shelf
/// again — the exact App Review rejection 3.2.2 exists to fix. This test
/// runs inside the app bundle, so `Bundle.main` is the app's, and CI fails
/// instead of shipping.
final class SampleBookResourceTests: XCTestCase {

    func testTheSampleBookIsInTheAppBundle() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "alice-in-wonderland", withExtension: "epub"),
            "alice-in-wonderland.epub is missing from \(Bundle.main.bundlePath) — check the epub resource rule in project.yml"
        )
        let size = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        )
        XCTAssertGreaterThan(size.intValue, 10_000, "the bundled sample is not an empty placeholder")
    }
}
