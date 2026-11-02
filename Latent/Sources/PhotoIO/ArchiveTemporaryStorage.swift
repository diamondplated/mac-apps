import Foundation
import Darwin

/// Only directories created by this version carry a lease. Legacy/unmarked trees are
/// deliberately left alone. flock survives threads and is released by process death.
public enum ArchiveTemporaryStorage {
    private static let marker = ".latent-extraction-lease-v2"
    private static let legacyMarker = ".latent-extraction-lease-v1"
    private static let completed = ".latent-extraction-complete-v1"
    private static let leases = Leases()

    private final class Leases: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptors: [String: Int32] = [:]
        func retain(_ fd: Int32, at url: URL) {
            lock.lock(); defer { lock.unlock() }
            descriptors[url.path] = fd
        }
        func duplicate(at url: URL) throws -> Int32 {
            lock.lock(); defer { lock.unlock() }
            guard let descriptor = descriptors[url.path] else { throw POSIXError(.ENOENT) }
            let copy = dup(descriptor)
            guard copy >= 0 else { throw POSIXError(.EIO) }
            return copy
        }
        func release(at url: URL) {
            lock.lock(); defer { lock.unlock() }
            if let fd = descriptors.removeValue(forKey: url.path) { Darwin.close(fd) }
        }
    }

    public static func createDirectory(root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let id = UUID().uuidString
        let directory = root.appendingPathComponent("pv-archive-\(id)", isDirectory: true)
        let preparing = root.appendingPathComponent("pv-archive-preparing-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: preparing, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: preparing) } }
        let fd = Darwin.open(preparing.appendingPathComponent(marker).path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        // Publish only after locking: a concurrent sweeper must never observe
        // a new, momentarily unlocked lease before the creating process owns it.
        do { try FileManager.default.moveItem(at: preparing, to: directory) }
        catch { Darwin.close(fd); throw error }
        published = true
        leases.retain(fd, at: directory)
        return directory
    }

    /// Called only after the extraction subprocess exits and tree validation succeeds.
    /// Retained for compatibility with directories created by older builds.
    public static func markCompleted(_ directory: URL) throws {
        let fd = Darwin.open(directory.appendingPathComponent(completed).path,
                             O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        Darwin.close(fd)
    }

    static func inheritedLease(_ directory: URL) throws -> FileHandle {
        FileHandle(fileDescriptor: try leases.duplicate(at: directory), closeOnDealloc: true)
    }

    public static func remove(_ directory: URL) throws {
        // Drop only our reference. A still-running supervisor must keep the tree,
        // even when cancellation or shutdown reaches this cleanup path.
        leases.release(at: directory)
        let fd = Darwin.open(directory.appendingPathComponent(marker).path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.ENOENT) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        try FileManager.default.removeItem(at: directory)
    }

    public static func sweepInactiveDirectories(root: URL = FileManager.default.temporaryDirectory) throws {
        let fm = FileManager.default
        for directory in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard directory.lastPathComponent.hasPrefix("pv-archive-"),
                  UUID(uuidString: String(directory.lastPathComponent.dropFirst("pv-archive-".count))) != nil else { continue }
            var directoryStat = stat()
            guard lstat(directory.path, &directoryStat) == 0,
                  directoryStat.st_uid == getuid(), directoryStat.st_mode & S_IFMT == S_IFDIR else { continue }
            var leasePath = directory.appendingPathComponent(marker)
            if !fm.fileExists(atPath: leasePath.path) {
                // Old builds did not transfer a lease to the extractor. Their
                // unfinished trees cannot safely be reclaimed by this version.
                var completedStat = stat()
                guard lstat(directory.appendingPathComponent(completed).path, &completedStat) == 0,
                      completedStat.st_uid == getuid(), completedStat.st_mode & S_IFMT == S_IFREG else { continue }
                leasePath = directory.appendingPathComponent(legacyMarker)
            }
            let fd = Darwin.open(leasePath.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            var markerStat = stat()
            guard fstat(fd, &markerStat) == 0, markerStat.st_uid == getuid(),
                  markerStat.st_mode & S_IFMT == S_IFREG,
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            try fm.removeItem(at: directory)
        }
    }
}
