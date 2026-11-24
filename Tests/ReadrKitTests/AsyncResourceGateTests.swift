import XCTest
@testable import ReadrKit

final class AsyncResourceGateTests: XCTestCase {
    func testQueuedCancellationReturnsBeforeOwnerFinishesAndDoesNotLeakLease() async throws {
        let gate = AsyncResourceGate()
        let owner = try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        while await gate.waitingCount == 0 { await Task.yield() }
        waiter.cancel()
        do { _ = try await waiter.value; XCTFail("cancelled waiter acquired") } catch is CancellationError { }
        let count = await gate.waitingCount
        XCTAssertEqual(count, 0)
        await gate.release(owner)
        let next = try await gate.acquire()
        await gate.release(next)
    }
    func testAStaleReleaseCannotAdmitTwoGraphs() async throws {
        let gate = AsyncResourceGate()
        let first = try await gate.acquire()
        await gate.release(first)
        let second = try await gate.acquire()
        await gate.release(first)
        let waiting = Task { try await gate.acquire() }
        while await gate.waitingCount == 0 { await Task.yield() }
        let count = await gate.waitingCount
        XCTAssertEqual(count, 1)
        await gate.release(second)
        await gate.release(try await waiting.value)
    }
    func testCancellationWhileHoldingAnotherResourceReleasesTheEarlierGate() async throws {
        let speech = AsyncResourceGate(), shared = AsyncResourceGate()
        let languageModel = try await shared.acquire()
        let cancelledSpeech = Task {
            let privateLease = try await speech.acquire()
            do {
                let globalLease = try await shared.acquire()
                await shared.release(globalLease)
                await speech.release(privateLease)
            } catch { await speech.release(privateLease); throw error }
        }
        while await shared.waitingCount == 0 { await Task.yield() }
        cancelledSpeech.cancel()
        do { try await cancelledSpeech.value; XCTFail("expected cancellation") } catch is CancellationError { }
        let subsequentSpeech = try await speech.acquire()
        await speech.release(subsequentSpeech)
        await shared.release(languageModel)
    }
}
