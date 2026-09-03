import XCTest
@testable import ReadrKit

/// Which engine speaks a request. The router in the app applies this table
/// per sentence; every row is pinned here because the failure modes on
/// either side of it are ugly — a Kokoro request on a crash-prone CoreML
/// build kills the process, and MLX GPU work started with the screen locked
/// aborts it (mlx-swift#274).
final class NarrationEnginePolicyTests: XCTestCase {

    private typealias Situation = NarrationEnginePolicy.Situation

    // MARK: - Platform voices

    func testAPlatformVoiceIsAlwaysThePlatformEngine() {
        // Whatever the Kokoro runtimes are doing, a request that did not ask
        // for Readr Voice never lands on one.
        for coreML in [false, true] {
            for mlxAvailable in [false, true] {
                for mlxReady in [false, true] {
                    for foreground in [false, true] {
                        let situation = Situation(
                            requestsReadrVoice: false,
                            coreMLKokoroUsable: coreML,
                            mlxKokoroAvailable: mlxAvailable,
                            mlxKokoroReady: mlxReady,
                            isForeground: foreground
                        )
                        XCTAssertEqual(
                            NarrationEnginePolicy.engine(for: situation), .platform,
                            "\(situation)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Readr Voice on macOS (no MLX engine)

    func testReadrVoiceOnMacOSUsesCoreMLWhenUsable() {
        let situation = Situation(
            requestsReadrVoice: true, coreMLKokoroUsable: true,
            mlxKokoroAvailable: false, mlxKokoroReady: false, isForeground: true
        )
        XCTAssertEqual(NarrationEnginePolicy.engine(for: situation), .coreMLKokoro)
    }

    func testReadrVoiceOnMacOSFallsToPlatformWhileCoreMLIsNotUsable() {
        // Downloading, failed, or the OS gate: the platform voice reads.
        let situation = Situation(
            requestsReadrVoice: true, coreMLKokoroUsable: false,
            mlxKokoroAvailable: false, mlxKokoroReady: false, isForeground: true
        )
        XCTAssertEqual(NarrationEnginePolicy.engine(for: situation), .platform)
    }

    func testMacOSIgnoresForegroundForCoreML() {
        // CoreML has no background restriction; the flag is an MLX concern.
        let situation = Situation(
            requestsReadrVoice: true, coreMLKokoroUsable: true,
            mlxKokoroAvailable: false, mlxKokoroReady: false, isForeground: false
        )
        XCTAssertEqual(NarrationEnginePolicy.engine(for: situation), .coreMLKokoro)
    }

    // MARK: - Readr Voice on iOS (MLX engine present)

    func testReadrVoiceOnIOSUsesMLXWhenReadyAndInForeground() {
        let situation = Situation(
            requestsReadrVoice: true, coreMLKokoroUsable: false,
            mlxKokoroAvailable: true, mlxKokoroReady: true, isForeground: true
        )
        XCTAssertEqual(NarrationEnginePolicy.engine(for: situation), .mlxKokoro)
    }

    func testReadrVoiceOnIOSFallsToPlatformWhileMLXIsNotReady() {
        let situation = Situation(
            requestsReadrVoice: true, coreMLKokoroUsable: false,
            mlxKokoroAvailable: true, mlxKokoroReady: false, isForeground: true
        )
        XCTAssertEqual(NarrationEnginePolicy.engine(for: situation), .platform)
    }

    func testReadrVoiceOnIOSFallsToPlatformWithTheScreenLocked() {
        // Metal refuses GPU work from a backgrounded app and the failure is
        // an uncatchable abort, so a ready MLX engine still steps aside.
        let situation = Situation(
            requestsReadrVoice: true, coreMLKokoroUsable: false,
            mlxKokoroAvailable: true, mlxKokoroReady: true, isForeground: false
        )
        XCTAssertEqual(NarrationEnginePolicy.engine(for: situation), .platform)
    }

    func testIOSNeverFallsBackToCoreMLEvenWhenItLooksUsable() {
        // iOS 26.3 and earlier pass the CoreML OS gate, but with an MLX engine
        // on the platform CoreML is never entered — one runtime per platform,
        // one model download, and no BNNS exposure at all.
        for mlxReady in [false, true] {
            for foreground in [false, true] {
                let situation = Situation(
                    requestsReadrVoice: true, coreMLKokoroUsable: true,
                    mlxKokoroAvailable: true, mlxKokoroReady: mlxReady,
                    isForeground: foreground
                )
                XCTAssertNotEqual(
                    NarrationEnginePolicy.engine(for: situation), .coreMLKokoro,
                    "\(situation)"
                )
            }
        }
    }

    // MARK: - The whole table

    func testEveryRowOfTheTable() {
        struct Row {
            let readr: Bool, coreML: Bool, mlxAvail: Bool, mlxReady: Bool, fg: Bool
            let expected: NarrationEngineChoice
        }
        // Enumerated in full so a future rule change has to edit a row here,
        // not just pass the narrative tests above.
        var rows: [Row] = []
        for readr in [false, true] {
            for coreML in [false, true] {
                for mlxAvail in [false, true] {
                    for mlxReady in [false, true] {
                        for fg in [false, true] {
                            let expected: NarrationEngineChoice
                            if !readr {
                                expected = .platform
                            } else if mlxAvail {
                                expected = (mlxReady && fg) ? .mlxKokoro : .platform
                            } else if coreML {
                                expected = .coreMLKokoro
                            } else {
                                expected = .platform
                            }
                            rows.append(Row(
                                readr: readr, coreML: coreML, mlxAvail: mlxAvail,
                                mlxReady: mlxReady, fg: fg, expected: expected
                            ))
                        }
                    }
                }
            }
        }
        XCTAssertEqual(rows.count, 32)
        for row in rows {
            let situation = Situation(
                requestsReadrVoice: row.readr, coreMLKokoroUsable: row.coreML,
                mlxKokoroAvailable: row.mlxAvail, mlxKokoroReady: row.mlxReady,
                isForeground: row.fg
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
