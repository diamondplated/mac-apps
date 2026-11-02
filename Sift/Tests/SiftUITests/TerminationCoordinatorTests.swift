import Testing
import TestSupport
@testable import SiftUI

@MainActor
private final class DrainBarrier {
    var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
@Test(.engineLifetime) func terminationDefersReplyUntilDrainAndClosesAdmissionImmediately() async throws {
    let coordinator = TerminationCoordinator()
    let barrier = DrainBarrier()
    defer { barrier.release() }
    var stopped = false
    var replies = 0
    coordinator.request(stopAdmission: {
        #expect(coordinator.isClosing)
        stopped = true
    }, drain: {
        #expect(stopped)
        await barrier.wait()
    }, reply: {
        #expect(coordinator.isClosing)
        replies += 1
    })
    #expect(stopped)
    #expect(coordinator.isClosing)
    #expect(replies == 0)
    try #require(await waitFor { barrier.entered })
    // The main actor can run this assertion while drain is suspended.
    #expect(replies == 0)
    barrier.release()
    try #require(await waitFor { replies == 1 })
    #expect(coordinator.isClosing, "the UI must remain closed through AppKit's final reply")
}

@MainActor
@Test(.engineLifetime) func terminationCoalescesRequestsBeforeAndAfterTheReply() async throws {
    let coordinator = TerminationCoordinator()
    let barrier = DrainBarrier()
    defer { barrier.release() }
    var stops = 0
    var drains = 0
    var replies = 0
    let request = {
        coordinator.request(stopAdmission: { stops += 1 }, drain: {
            drains += 1
            await barrier.wait()
        }, reply: { replies += 1 })
    }
    request()
    try #require(await waitFor { barrier.entered })
    request()
    #expect(stops == 1, "a repeated quit request must not start a second shutdown")
    #expect(replies == 0)
    barrier.release()
    try #require(await waitFor { replies >= 1 })
    request()
    #expect(stops == 1)
    #expect(drains == 1)
    #expect(replies == 1)
    #expect(coordinator.isClosing)
}

@MainActor
@Test(.engineLifetime) func terminationRejectsReentrantRequestsFromAdmissionAndReply() async throws {
    let coordinator = TerminationCoordinator()
    var nested = 0
    var replies = 0
    let reenter = {
        coordinator.request(stopAdmission: { nested += 1 }, drain: {}, reply: { nested += 1 })
    }
    coordinator.request(stopAdmission: reenter, drain: {}, reply: {
        replies += 1
        reenter()
    })
    #expect(nested == 0)
    try #require(await waitFor { replies == 1 })
    #expect(nested == 0)
    #expect(coordinator.isClosing)
}
