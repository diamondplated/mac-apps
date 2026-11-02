import Foundation
import Testing
import TestSupport
@testable import SiftEngine

private actor LifetimeGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; let ready = waiters; waiters.removeAll(); for waiter in ready { waiter.resume() } }
}

private final class LifetimeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@Test(.engineLifetime)
func shutdownDrainsOwnedStagingBeforeReleasingItsHomeAndRejectsLateWork() async throws {
    let home = TestTemp.path("lifetime-home")
    let path = TestTemp.path("lifetime", ".csv")
    try "id\n1\n2\n".write(toFile: path, atomically: true, encoding: .utf8)
    let session = try Session(home: home)
    let table = try await session.openPath(path)
    let entered = LifetimeGate(), release = LifetimeGate()
    await session.setStageBarrierForTest { await entered.release(); await release.wait() }
    _ = try #require(try await session.stageNow(table.name, force: true))
    await entered.wait()
    let finished = LifetimeFlag()
    let shutdown = Task { await session.shutdown(); finished.set() }
    while !(await session.isClosing) { await Task.yield() }
    #expect(!finished.isSet, "shutdown must wait for the actual staging task")
    #expect(throws: SessionError.self) { _ = try Session(home: home) }
    await #expect(throws: SessionError.self) { _ = try await session.openPath(path) }
    await #expect(throws: SessionError.self) { _ = try await session.stageNow(table.name, force: true) }
    await #expect(throws: SessionError.self) { _ = try await session.page(table.name, offset: 0) }
    await release.release()
    await shutdown.value
    // Keep the negative-control mutation safe: it deliberately removes shutdown's drain.
    await session.ownedWork.drain()
    #expect(finished.isSet)
    let replacement = try Session(home: home)
    await replacement.shutdown()
    await session.shutdown()  // idempotent; cannot release the replacement's claim
}

@Test(.engineLifetime, arguments: [false, true])
func aThrowingLifetimeScopeStillDrainsItsOwnedStaging(cancel: Bool) async throws {
    enum Expected: Error { case failure }
    let path = TestTemp.path("lifetime-throw", ".csv")
    try "id\n1\n".write(toFile: path, atomically: true, encoding: .utf8)
    let entered = LifetimeGate(), release = LifetimeGate()
    let finished = LifetimeFlag()
    let run = Task {
        do {
            try await SessionLifetime.withScope {
                let session = try Session(home: TestTemp.path("lifetime-throw-home"))
                let table = try await session.openPath(path)
                await session.setStageBarrierForTest { await entered.release(); await release.wait() }
                _ = try #require(try await session.stageNow(table.name, force: true))
                await entered.wait()
                throw Expected.failure
            }
            Issue.record("expected the scope's error")
        } catch Expected.failure { finished.set() }
        catch { Issue.record("unexpected error: \(error)") }
    }
    await entered.wait()
    if cancel { run.cancel() }
    #expect(!finished.isSet)
    await release.release()
    await run.value
    #expect(finished.isSet)
}
