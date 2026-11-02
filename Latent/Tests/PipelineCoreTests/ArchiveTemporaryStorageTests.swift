import Foundation
import Darwin
import XCTest
import PhotoIO

final class ArchiveTemporaryStorageTests: XCTestCase {
    private actor Completion {
        var finished = false
        func finish() { finished = true }
    }

    func testLaunchReclaimerSnapshotsBusyV2AndSupportsCancellation() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("latent-reclaimer-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let busy = root.appendingPathComponent("pv-archive-\(UUID().uuidString)")
        try fm.createDirectory(at: busy, withIntermediateDirectories: false)
        let fd = Darwin.open(busy.appendingPathComponent(".latent-extraction-lease-v2").path,
                             O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let local = try ArchiveTemporaryStorage.createDirectory(root: root)
        defer { try? ArchiveTemporaryStorage.remove(local) }
        let legacy = root.appendingPathComponent("pv-archive-\(UUID().uuidString)")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: false)
        try Data().write(to: legacy.appendingPathComponent(".latent-extraction-lease-v1"))
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("photo"))
        let link = root.appendingPathComponent("pv-archive-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let completion = Completion()
        let reclaimer = Task {
            try await ArchiveTemporaryStorage.reclaimOnLaunch(root: root)
            await completion.finish()
        }
        defer { reclaimer.cancel() }
        try await Task.sleep(nanoseconds: 350_000_000)
        // A v2 tree created after the snapshot must never join the retry set.
        let later = root.appendingPathComponent("pv-archive-\(UUID().uuidString)")
        try fm.createDirectory(at: later, withIntermediateDirectories: false)
        try Data().write(to: later.appendingPathComponent(".latent-extraction-lease-v2"))
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        let deadline = Date().addingTimeInterval(3)
        while fm.fileExists(atPath: busy.path) && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(fm.fileExists(atPath: busy.path))
        for preserved in [local, legacy, link, outside, later] {
            XCTAssertTrue(fm.fileExists(atPath: preserved.path))
        }
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("photo")), Data("keep".utf8))
        let completionDeadline = Date().addingTimeInterval(1)
        while !(await completion.finished) && Date() < completionDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let finished = await completion.finished
        XCTAssertTrue(finished, "local leases must not keep the launch reclaimer polling")
        reclaimer.cancel()
        do { try await reclaimer.value } catch is CancellationError {}

        // Cancellation interrupts backoff and leaves an active candidate intact.
        try fm.createDirectory(at: busy, withIntermediateDirectories: false)
        let held = Darwin.open(busy.appendingPathComponent(".latent-extraction-lease-v2").path,
                               O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        guard held >= 0 else { XCTFail("fixture lock failed"); return }
        defer { Darwin.close(held) }
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        let cancelled = Task { try await ArchiveTemporaryStorage.reclaimOnLaunch(root: root) }
        try await Task.sleep(nanoseconds: 350_000_000)
        let started = Date()
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertTrue(fm.fileExists(atPath: busy.path))

        // A path replacement must leave the work set rather than authorize
        // deletion using a lease observed on the previous directory's inode.
        let replacedCompletion = Completion()
        let replaced = Task {
            try await ArchiveTemporaryStorage.reclaimOnLaunch(root: root)
            await replacedCompletion.finish()
        }
        defer { replaced.cancel() }
        try await Task.sleep(nanoseconds: 350_000_000)
        let retired = root.appendingPathComponent("retired-original")
        try fm.moveItem(at: busy, to: retired)
        try fm.createDirectory(at: busy, withIntermediateDirectories: false)
        try Data().write(to: busy.appendingPathComponent(".latent-extraction-lease-v2"))
        let replacementDeadline = Date().addingTimeInterval(2)
        while !(await replacedCompletion.finished) && Date() < replacementDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let replacementFinished = await replacedCompletion.finished
        XCTAssertTrue(replacementFinished)
        XCTAssertTrue(fm.fileExists(atPath: busy.path), "replacement must not inherit the old candidate's deletion eligibility")
        XCTAssertTrue(fm.fileExists(atPath: retired.path))
        replaced.cancel()
        do { try await replaced.value } catch is CancellationError {}
    }

    func testSweepPreservesActiveUnmarkedAndSymlinkDirectories() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let active = try ArchiveTemporaryStorage.createDirectory(root: root)
        defer { try? ArchiveTemporaryStorage.remove(active) }
        try ArchiveTemporaryStorage.markCompleted(active)
        let stale = root.appendingPathComponent("pv-archive-\(UUID().uuidString)")
        let inFlight = root.appendingPathComponent("pv-archive-\(UUID().uuidString)")
        let unmarked = root.appendingPathComponent("pv-archive-\(UUID().uuidString)")
        for dir in [stale, unmarked, inFlight] { try fm.createDirectory(at: dir, withIntermediateDirectories: false) }
        try Data().write(to: stale.appendingPathComponent(".latent-extraction-lease-v1"))
        try ArchiveTemporaryStorage.markCompleted(stale)
        try Data().write(to: inFlight.appendingPathComponent(".latent-extraction-lease-v1"))
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("photo"))
        let link = root.appendingPathComponent("pv-archive-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        try ArchiveTemporaryStorage.sweepInactiveDirectories(root: root)
        XCTAssertFalse(fm.fileExists(atPath: stale.path))
        for dir in [active, unmarked, inFlight, link, outside] { XCTAssertTrue(fm.fileExists(atPath: dir.path)) }
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("photo")), Data("keep".utf8))
    }
}
