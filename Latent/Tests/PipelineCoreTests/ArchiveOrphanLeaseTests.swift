import Foundation
import Darwin
import XCTest
@testable import PhotoIO

final class ArchiveOrphanLeaseTests: XCTestCase {
    func testParentDeathPreservesLiveExtractorThenReclaimsUnfinishedTree() throws {
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
        try ArchiveTemporaryStorage.sweepInactiveDirectories(root: root)
        XCTAssertTrue(fm.fileExists(atPath: directory.path), "live orphan must retain extraction")
        try Data().write(to: done)
        let end = Date().addingTimeInterval(10)
        while fm.fileExists(atPath: directory.path) && Date() < end {
            try ArchiveTemporaryStorage.sweepInactiveDirectories(root: root)
            usleep(10_000)
        }
        XCTAssertFalse(fm.fileExists(atPath: directory.path), "finished orphan must release lease without completion marker")
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
}
