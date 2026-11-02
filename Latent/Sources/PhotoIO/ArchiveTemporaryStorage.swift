import Foundation
import Darwin

/// Only directories created by this version carry a lease. Legacy/unmarked trees are
/// deliberately left alone. flock survives threads and is released by process death.
public enum ArchiveTemporaryStorage {
    private static let marker = ".latent-extraction-lease-v1"
    private static let completed = ".latent-extraction-complete-v1"
    private static let leases = Leases()

    private final class Leases: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptors: [String: Int32] = [:]
        func retain(_ fd: Int32, at url: URL) {
            lock.lock(); defer { lock.unlock() }
            descriptors[url.path] = fd
        }
        func release(at url: URL) {
            lock.lock(); defer { lock.unlock() }
            if let fd = descriptors.removeValue(forKey: url.path) { Darwin.close(fd) }
        }
    }

    public static func createDirectory(root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = root.appendingPathComponent("pv-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent(marker).path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(.EIO)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(.EIO)
        }
        leases.retain(fd, at: directory)
        return directory
    }

    /// Called only after the extraction subprocess exits and tree validation succeeds.
    /// In-flight crash trees remain untouched: their orphaned writer may still be alive.
    public static func markCompleted(_ directory: URL) throws {
        let fd = Darwin.open(directory.appendingPathComponent(completed).path,
                             O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        Darwin.close(fd)
    }

    public static func remove(_ directory: URL) throws {
        // Release only after removal so a concurrent sweep cannot race active cleanup.
        try FileManager.default.removeItem(at: directory)
        leases.release(at: directory)
    }

    public static func sweepInactiveDirectories(root: URL = FileManager.default.temporaryDirectory) throws {
        let fm = FileManager.default
        for directory in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard directory.lastPathComponent.hasPrefix("pv-archive-"),
                  UUID(uuidString: String(directory.lastPathComponent.dropFirst("pv-archive-".count))) != nil else { continue }
            var directoryStat = stat()
            guard lstat(directory.path, &directoryStat) == 0,
                  directoryStat.st_uid == getuid(), directoryStat.st_mode & S_IFMT == S_IFDIR else { continue }
            var completedStat = stat()
            guard lstat(directory.appendingPathComponent(completed).path, &completedStat) == 0,
                  completedStat.st_uid == getuid(), completedStat.st_mode & S_IFMT == S_IFREG else { continue }
            let fd = Darwin.open(directory.appendingPathComponent(marker).path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
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
