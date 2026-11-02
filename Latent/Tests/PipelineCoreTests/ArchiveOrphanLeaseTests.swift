import Foundation
import Darwin
import XCTest
@testable import PhotoIO

final class ArchiveOrphanLeaseTests: XCTestCase {
    func testParentDeathPreservesLiveExtractorThenReclaimsUnfinishedTree() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("latent-orphan-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let directory = try ArchiveTemporaryStorage.createDirectory(root: root)
        let ready = root.appendingPathComponent("ready")
        let done = root.appendingPathComponent("done")
        // Python is only a disposable fixture parent; production uses /bin/sh.
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        parent.arguments = ["-c", #"""
import os, subprocess, sys, time
supervisor = subprocess.Popen(['/bin/sh', '-c', sys.argv[1], 'fixture', '/bin/sh', '-c',
    'printf ready > "$1"; while [ ! -e "$2" ]; do sleep 0.02; done', 'tool', sys.argv[2], sys.argv[3]], stdin=sys.stdin)
while not os.path.exists(sys.argv[2]): time.sleep(0.01)
print(supervisor.pid, flush=True)
while True: time.sleep(1)
"""#, ArchiveProcessLease.supervisor, ready.path, done.path]
        let handle = try ArchiveTemporaryStorage.inheritedLease(directory)
        parent.standardInput = handle
        let output = Pipe()
        parent.standardOutput = output
        parent.standardError = FileHandle.nullDevice
        try parent.run()
        // Process retains its stdin FileHandle, so explicitly close our duplicate.
        try handle.close()
        defer {
            try? Data().write(to: done)
            if parent.isRunning { kill(parent.processIdentifier, SIGKILL); parent.waitUntilExit() }
        }
        let deadline = Date().addingTimeInterval(10)
        while !fm.fileExists(atPath: ready.path) && Date() < deadline { usleep(10_000) }
        XCTAssertTrue(fm.fileExists(atPath: ready.path))
        // Drop the app's descriptor; cleanup itself must refuse while the child owns it.
        XCTAssertThrowsError(try ArchiveTemporaryStorage.remove(directory))
        kill(parent.processIdentifier, SIGKILL)
        parent.waitUntilExit()
        // One launch invocation must preserve the live orphan and then reclaim
        // automatically. The test never drives a second sweep after tool exit.
        let reclaimer = Task { try await ArchiveTemporaryStorage.reclaimOnLaunch(root: root) }
        defer { reclaimer.cancel() }
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(fm.fileExists(atPath: directory.path), "live orphan must retain extraction")
        try Data().write(to: done)
        let end = Date().addingTimeInterval(5)
        while fm.fileExists(atPath: directory.path) && Date() < end {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(fm.fileExists(atPath: directory.path), "same launch reclaimer must remove finished orphan without completion marker")
        reclaimer.cancel()
        do { try await reclaimer.value } catch is CancellationError {}
    }

    func testSupervisorCancellationStopsToolBeforeReleasingLease() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("latent-cancel-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let directory = try ArchiveTemporaryStorage.createDirectory(root: root)
        let ready = root.appendingPathComponent("ready")
        let process = Process()
        try ArchiveProcessLease.configure(process, tool: "/bin/sh", arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 60", "tool", ready.path], directory: directory)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try (process.standardInput as? FileHandle)?.close()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(10)
        while !fm.fileExists(atPath: ready.path) && Date() < deadline { usleep(10_000) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: ready, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertThrowsError(try ArchiveTemporaryStorage.remove(directory), "configured supervisor must hold the inherited lease")
        process.terminate()
        process.waitUntilExit()
        XCTAssertEqual(kill(pid, 0), -1, "tool must be reaped before supervisor exits")
        XCTAssertEqual(errno, ESRCH)
        try ArchiveTemporaryStorage.remove(directory)
        XCTAssertFalse(fm.fileExists(atPath: directory.path))
    }
    func testCancellationRetainsLeaseUntilDelayedDescendantExits() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("latent-descendant-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let directory = try ArchiveTemporaryStorage.createDirectory(root: root)
        let ready = root.appendingPathComponent("ready")
        let done = root.appendingPathComponent("done")
        let process = Process()
        let tool = #"""
        /bin/sh -c 'echo $$ > "$1"; while [ ! -e "$2" ]; do /bin/sleep 0.02; done' descendant "$1" "$2" &
        wait
        """#
        try ArchiveProcessLease.configure(process, tool: "/bin/sh", arguments: ["-c", tool, "tool", ready.path, done.path], directory: directory)
        // Fault injection makes group termination delayed: kill only the leader,
        // leaving the real descendant alive until the fixture releases it. This
        // deterministically tests the gap between leader death and descendant exit.
        let delayedGroupSignal = #"""
        kill() {
            if [ "$1" = -KILL ] && [ "$2" = -- ]; then
                command kill -KILL "${3#-}"
            else
                command kill "$@"
            fi
        }
        """#
        process.arguments?[1] = delayedGroupSignal + "\n" + ArchiveProcessLease.supervisor
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try (process.standardInput as? FileHandle)?.close()
        defer {
            try? Data().write(to: done)
            if process.isRunning { process.terminate() }
        }
        let startDeadline = Date().addingTimeInterval(10)
        while !fm.fileExists(atPath: ready.path) && Date() < startDeadline { usleep(10_000) }
        XCTAssertTrue(fm.fileExists(atPath: ready.path))
        process.terminate()
        usleep(150_000)
        XCTAssertTrue(process.isRunning, "leader death must not release the descendant's lease")
        XCTAssertThrowsError(try ArchiveTemporaryStorage.remove(directory))
        try ArchiveTemporaryStorage.sweepInactiveDirectories(root: root)
        XCTAssertTrue(fm.fileExists(atPath: directory.path))
        try Data().write(to: done)
        let exitDeadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < exitDeadline { usleep(10_000) }
        XCTAssertFalse(process.isRunning, "supervisor must finish once descendants exit")
        try ArchiveTemporaryStorage.remove(directory)
    }

    func testCancellationReturnsWhileStoppedSupervisorKeepsLease() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("latent-stopped-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let directory = try ArchiveTemporaryStorage.createDirectory(root: root)
        let ready = root.appendingPathComponent("ready")
        let extractor = ArchiveExtractor()
        let task = Task {
            try await extractor.runProcess(tool: "/bin/sh", args: ["-c", #"""
            kill -STOP "$PPID"
            echo "$PPID" > "$1"
            exec /bin/sleep 60
            """#, "tool", ready.path], inputArchive: root.appendingPathComponent("fixture.zip"), destination: directory)
        }
        let deadline = Date().addingTimeInterval(10)
        while !fm.fileExists(atPath: ready.path) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let supervisor = try XCTUnwrap(Int32(String(contentsOf: ready, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(supervisor, SIGCONT) }
        let started = Date()
        task.cancel()
        do { try await task.value; XCTFail("expected cancellation") }
        catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "cancellation cannot wait indefinitely for supervisor or pipe drainers")
        XCTAssertThrowsError(try ArchiveTemporaryStorage.remove(directory))
        try ArchiveTemporaryStorage.sweepInactiveDirectories(root: root)
        XCTAssertTrue(fm.fileExists(atPath: directory.path))
        kill(supervisor, SIGCONT)
        let exitDeadline = Date().addingTimeInterval(5)
        while fm.fileExists(atPath: directory.path) && Date() < exitDeadline {
            try ArchiveTemporaryStorage.sweepInactiveDirectories(root: root)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(fm.fileExists(atPath: directory.path))
    }

}
