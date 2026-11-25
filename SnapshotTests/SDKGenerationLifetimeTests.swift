import XCTest
import ReadrKit
@testable import Readr

final class SDKGenerationLifetimeTests: XCTestCase {
    private actor Barrier {
        var continuation: CheckedContinuation<Void, Never>?
        var waiting = false
        func wait() async { await withCheckedContinuation { continuation = $0; waiting = true } }
        func release() { continuation?.resume(); continuation = nil }
    }
    func testEarlyStopRetainsOwnershipUntilSDKWorkerEnds() async throws {
        let gate = AsyncResourceGate(), barrier = Barrier()
        let token = try await gate.acquire()
        let worker = Task { await barrier.wait() }
        while !(await barrier.waiting) { await Task.yield() }
        let nextEntered = expectation(description: "next graph remains queued")
        nextEntered.isInverted = true
        let consumer = Task {
            _ = try await SDKGenerationLifetime.run(worker) { "repetition guard stopped" }
            await gate.release(token)
        }
        let next = Task {
            let token = try await gate.acquire()
            nextEntered.fulfill()
            await gate.release(token)
        }
        await fulfillment(of: [nextEntered], timeout: 0.1)
        await barrier.release()
        _ = try await consumer.value
        _ = try await next.value
    }
    func testCancelledConsumerDrainsWorkerBeforeReturning() async throws {
        let barrier = Barrier()
        let worker = Task { await barrier.wait() }
        while !(await barrier.waiting) { await Task.yield() }
        let returned = expectation(description: "cancelled consumer drains")
        returned.isInverted = true
        let consumer = Task {
            do { _ = try await SDKGenerationLifetime.run(worker) { throw CancellationError() } }
            catch { }
            returned.fulfill()
        }
        consumer.cancel()
        await fulfillment(of: [returned], timeout: 0.1)
        await barrier.release()
        await consumer.value
    }
}
