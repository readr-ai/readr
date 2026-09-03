import XCTest
@testable import ReadrKit

/// Which engine speaks a request. The router in the app applies this table
/// per sentence; every row is pinned here because the failure modes on
/// either side of it are ugly — a Kokoro request on a crash-prone CoreML
/// build kills the process, and an Apple voice reading a Readr Voice book
/// is the thing 3.3.1 exists to end.
final class NarrationEnginePolicyTests: XCTestCase {

    private typealias Situation = NarrationEnginePolicy.Situation

    // MARK: - Platform voices

    func testAPlatformVoiceIsAlwaysThePlatformEngine() {
        // Whatever the Kokoro runtimes are doing, a request that did not ask
        // for Readr Voice never lands on one.
        for coreML in [false, true] {
            for mlxAvailable in [false, true] {
                for mlxFailed in [false, true] {
                    let situation = Situation(
                        requestsReadrVoice: false,
                        coreMLKokoroAvailable: coreML,
                        mlxKokoroAvailable: mlxAvailable,
                        mlxKokoroFailed: mlxFailed
                    )
                    XCTAssertEqual(
                        NarrationEnginePolicy.engine(for: situation), .platform,
                        "\(situation)"
                    )
                }
            }
        }
    }

    // MARK: - Readr Voice on macOS (no MLX engine)

    func testReadrVoiceOnMacOSUsesCoreMLWheneverItCanServe() {
        // Loaded or still downloading alike: the engine waits for its model
        // and narration shows "preparing" — no Apple voice meanwhile.
        let situation = Situation(
            requestsReadrVoice: true, coreMLKokoroAvailable: true,
            mlxKokoroAvailable: false, mlxKokoroFailed: false
        )
        XCTAssertEqual(NarrationEnginePolicy.engine(for: situation), .coreMLKokoro)
    }

    func testReadrVoiceOnMacOSFallsToPlatformOnlyWithoutACoreMLEngine() {
        // The OS gate (macOS 26.4–26.5) or a failed download: the request
        // should not have been a Readr Voice one, and the platform reads.
        let situation = Situation(
            requestsReadrVoice: true, coreMLKokoroAvailable: false,
            mlxKokoroAvailable: false, mlxKokoroFailed: false
        )
        XCTAssertEqual(NarrationEnginePolicy.engine(for: situation), .platform)
    }

    // MARK: - Readr Voice on iOS (MLX engine present)

    func testReadrVoiceOnIOSUsesMLXWhetherOrNotTheModelIsIn() {
        // No foreground and no readiness in the rule any more: the engine
        // plays from its buffer with the screen locked and waits for a
        // download rather than handing the sentence to an Apple voice.
        let situation = Situation(
            requestsReadrVoice: true, coreMLKokoroAvailable: false,
            mlxKokoroAvailable: true, mlxKokoroFailed: false
        )
        XCTAssertEqual(NarrationEnginePolicy.engine(for: situation), .mlxKokoro)
    }

    func testReadrVoiceOnIOSFallsToPlatformOnlyOnceMLXHasFailed() {
        // The one platform row for Readr Voice on iOS. The app never issues
        // a Readr Voice request to a failed engine without re-preparing it
        // first, so this row is a backstop, not a fallback the reader hears.
        let situation = Situation(
            requestsReadrVoice: true, coreMLKokoroAvailable: false,
            mlxKokoroAvailable: true, mlxKokoroFailed: true
        )
        XCTAssertEqual(NarrationEnginePolicy.engine(for: situation), .platform)
    }

    func testIOSNeverFallsBackToCoreMLEvenWhenItLooksUsable() {
        // iOS 26.3 and earlier pass the CoreML OS gate, but with an MLX engine
        // on the platform CoreML is never entered — one runtime per platform,
        // one model download, and no BNNS exposure at all.
        for mlxFailed in [false, true] {
            let situation = Situation(
                requestsReadrVoice: true, coreMLKokoroAvailable: true,
                mlxKokoroAvailable: true, mlxKokoroFailed: mlxFailed
            )
            XCTAssertNotEqual(
                NarrationEnginePolicy.engine(for: situation), .coreMLKokoro,
                "\(situation)"
            )
        }
    }

    // MARK: - The whole table

    func testEveryRowOfTheTable() {
        struct Row {
            let readr: Bool, coreML: Bool, mlxAvail: Bool, mlxFailed: Bool
            let expected: NarrationEngineChoice
        }
        // Enumerated in full so a future rule change has to edit a row here,
        // not just pass the narrative tests above.
        var rows: [Row] = []
        for readr in [false, true] {
            for coreML in [false, true] {
                for mlxAvail in [false, true] {
                    for mlxFailed in [false, true] {
                        let expected: NarrationEngineChoice
                        if !readr {
                            expected = .platform
                        } else if mlxAvail {
                            expected = mlxFailed ? .platform : .mlxKokoro
                        } else if coreML {
                            expected = .coreMLKokoro
                        } else {
                            expected = .platform
                        }
                        rows.append(Row(
                            readr: readr, coreML: coreML, mlxAvail: mlxAvail,
                            mlxFailed: mlxFailed, expected: expected
                        ))
                    }
                }
            }
        }
        XCTAssertEqual(rows.count, 16)
        for row in rows {
            let situation = Situation(
                requestsReadrVoice: row.readr, coreMLKokoroAvailable: row.coreML,
                mlxKokoroAvailable: row.mlxAvail, mlxKokoroFailed: row.mlxFailed
            )
            XCTAssertEqual(
                NarrationEnginePolicy.engine(for: situation), row.expected, "\(situation)"
            )
        }
    }

    // MARK: - Which runtime to prepare

    func testThePlatformPreparesExactlyOneKokoroRuntime() {
        XCTAssertEqual(
            NarrationEnginePolicy.kokoroRuntime(mlxAvailable: true, coreMLSupported: true), .mlx
        )
        XCTAssertEqual(
            NarrationEnginePolicy.kokoroRuntime(mlxAvailable: true, coreMLSupported: false), .mlx
        )
        XCTAssertEqual(
            NarrationEnginePolicy.kokoroRuntime(mlxAvailable: false, coreMLSupported: true),
            .coreML
        )
        XCTAssertNil(
            NarrationEnginePolicy.kokoroRuntime(mlxAvailable: false, coreMLSupported: false)
        )
    }
}
