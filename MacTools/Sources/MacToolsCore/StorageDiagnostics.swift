import Foundation
import Darwin

public struct StorageIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64

    fileprivate init(_ info: stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = info.st_size
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }
}

public struct StorageFile: Codable, Identifiable, Hashable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let allocatedBytes: Int64
    public let logicalBytes: Int64
    public let identity: StorageIdentity
}

public struct StorageFolder: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let allocatedBytes: Int64
}

public struct StorageSnapshot: Codable, Sendable {
    public let rootPath: String
    public let rootIdentity: StorageIdentity
    public let completedAt: Date
    public let allocatedBytes: Int64
    public let logicalBytes: Int64
    public let fileCount: Int
    public let largestFiles: [StorageFile]
    public let folders: [StorageFolder]
    public let skippedCount: Int
    public let unreadableCount: Int
    public let wasLimited: Bool
    public var isComplete: Bool { !wasLimited && unreadableCount == 0 }

    public func growth(since previous: StorageSnapshot) -> Int64? {
        guard isComplete, previous.isComplete, rootPath == previous.rootPath,
              rootIdentity.device == previous.rootIdentity.device,
              rootIdentity.inode == previous.rootIdentity.inode else { return nil }
        return allocatedBytes - previous.allocatedBytes
    }
}

public enum StorageScanError: LocalizedError {
    case invalidRoot, remoteVolume, changedFile(String), outsideRoot, symlink, protectedLocation
    public var errorDescription: String? {
        switch self {
        case .invalidRoot: "Choose an existing local folder."
        case .remoteVolume: "SpaceWatch scans local volumes only."
        case .changedFile(let path): "\(path) changed since the scan. Scan again before moving it to Trash."
        case .outsideRoot: "The selected file is outside the scanned folder."
        case .symlink: "A path contains a symbolic link. Choose the original folder instead."
        case .protectedLocation: "System and Library files cannot be moved to Trash from SpaceWatch."
        }
    }
}

public enum StorageDiagnostics {
    public struct Limits: Sendable {
        public let maximumEntries: Int
        public let maximumSeconds: TimeInterval
        public let maximumResults: Int
        public init(maximumEntries: Int = 50_000, maximumSeconds: TimeInterval = 30, maximumResults: Int = 200) {
            self.maximumEntries = max(1, maximumEntries)
            self.maximumSeconds = max(0.001, maximumSeconds)
            self.maximumResults = max(1, maximumResults)
        }
    }

    private static func metadata(_ url: URL) throws -> stat {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return info
    }

    private static func normalizedURL(_ url: URL) -> URL {
        let path = url.standardized.path
        // Foundation's standardizedFileURL collapses /private/var back to /var.
        // Expand only macOS's fixed root aliases; all other symlinks remain rejected.
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return URL(fileURLWithPath: "/private" + path)
        }
        return URL(fileURLWithPath: path)
    }

    private static func rejectSymlinkAncestors(_ url: URL) throws {
        var current = normalizedURL(url)
        while current.path != "/" {
            let info = try metadata(current)
            guard info.st_mode & S_IFMT != S_IFLNK else { throw StorageScanError.symlink }
            current.deleteLastPathComponent()
        }
    }

    /// Runs synchronously on a background task; cancellation is checked during every directory and entry.
    public static func scan(root: URL, limits: Limits = Limits()) throws -> StorageSnapshot {
        try Task.checkCancellation()
        let root = normalizedURL(root)
        try rejectSymlinkAncestors(root)
        let rootInfo = try metadata(root)
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else { throw StorageScanError.invalidRoot }
        let rootResources = try root.resourceValues(forKeys: [.volumeIsLocalKey, .isUbiquitousItemKey])
        guard rootResources.volumeIsLocal == true, rootResources.isUbiquitousItem != true else {
            throw StorageScanError.remoteVolume
        }
        let began = ProcessInfo.processInfo.systemUptime
        var pending = [root]
        var files: [StorageFile] = []
        var folderBytes: [String: Int64] = [:]
        var seen: Set<String> = []
        var allocated: Int64 = 0, logical: Int64 = 0
        var count = 0, visited = 0, skipped = 0, unreadable = 0
        var limited = false
        let keys: Set<URLResourceKey> = [.isPackageKey, .isUbiquitousItemKey]
        outer: while let directory = pending.popLast() {
            try Task.checkCancellation()
            // opendir/readdir avoids materializing an unbounded directory listing.
            do { try rejectSymlinkAncestors(directory) } catch { unreadable += 1; continue }
            let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { unreadable += 1; continue }
            guard let stream = fdopendir(descriptor) else { close(descriptor); unreadable += 1; continue }
            defer { closedir(stream) }
            while let entry = readdir(stream) {
                try Task.checkCancellation()
                if visited >= limits.maximumEntries || ProcessInfo.processInfo.systemUptime - began >= limits.maximumSeconds {
                    limited = true
                    break outer
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                visited += 1
                let url = directory.appendingPathComponent(name)
                let info: stat
                do { info = try metadata(url) } catch { unreadable += 1; continue }
                let type = info.st_mode & S_IFMT
                guard info.st_dev == rootInfo.st_dev, type != S_IFLNK, info.st_flags & UInt32(SF_DATALESS) == 0 else { skipped += 1; continue }
                let resources: URLResourceValues
                do { resources = try url.resourceValues(forKeys: keys) } catch { unreadable += 1; continue }
                guard resources.isUbiquitousItem != true else { skipped += 1; continue }
                if type == S_IFDIR {
                    if resources.isPackage == true { skipped += 1 } else { pending.append(url) }
                    continue
                }
                guard type == S_IFREG else { skipped += 1; continue }
                // Hard-linked bytes belong to the volume once, even if there are multiple paths.
                guard seen.insert("\(info.st_dev):\(info.st_ino)").inserted else { skipped += 1; continue }
                let bytes = max(0, Int64(info.st_blocks) * 512)
                let relative = String(url.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
                allocated += bytes
                logical += max(0, info.st_size)
                count += 1
                let components = relative.split(separator: "/")
                let group = components.count > 1 ? String(components[0]) : "Files in this folder"
                folderBytes[group, default: 0] += bytes
                files.append(StorageFile(relativePath: relative, allocatedBytes: bytes,
                                         logicalBytes: max(0, info.st_size), identity: StorageIdentity(info)))
                if files.count > limits.maximumResults * 2 {
                    files.sort { $0.allocatedBytes > $1.allocatedBytes }
                    files.removeLast(files.count - limits.maximumResults)
                }
            }
        }
        return StorageSnapshot(rootPath: root.path, rootIdentity: StorageIdentity(rootInfo), completedAt: Date(),
                               allocatedBytes: allocated, logicalBytes: logical, fileCount: count,
                               largestFiles: Array(files.sorted { $0.allocatedBytes > $1.allocatedBytes }.prefix(limits.maximumResults)),
                               folders: folderBytes.map { StorageFolder(name: $0.key, allocatedBytes: $0.value) }.sorted { $0.allocatedBytes > $1.allocatedBytes },
                               skippedCount: skipped, unreadableCount: unreadable, wasLimited: limited)
    }

    /// Only regular files from the reviewed snapshot may be trashed; validate immediately before the OS operation.
    public static func validatedTrashURLs(files: [StorageFile], snapshot: StorageSnapshot) throws -> [URL] {
        let root = normalizedURL(URL(fileURLWithPath: snapshot.rootPath))
        try rejectSymlinkAncestors(root)
        let currentRoot = StorageIdentity(try metadata(root))
        guard currentRoot.device == snapshot.rootIdentity.device, currentRoot.inode == snapshot.rootIdentity.inode else {
            throw StorageScanError.changedFile(root.lastPathComponent)
        }
        let allowed = Set(snapshot.largestFiles)
        return try files.map { file in
            guard allowed.contains(file), !file.relativePath.isEmpty, !file.relativePath.hasPrefix("/") else {
                throw StorageScanError.outsideRoot
            }
            let url = normalizedURL(root.appendingPathComponent(file.relativePath))
            guard url.path != root.path, url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
                throw StorageScanError.outsideRoot
            }
            try rejectSymlinkAncestors(url)
            let parts = url.pathComponents
            let privateSystemPath = url.path.hasPrefix("/private/") &&
                !url.path.hasPrefix("/private/tmp/") && !url.path.hasPrefix("/private/var/folders/")
            guard !privateSystemPath, !parts.contains("Library"), !parts.contains("System"),
                  !["/bin/", "/sbin/", "/usr/", "/dev/"].contains(where: url.path.hasPrefix) else {
                throw StorageScanError.protectedLocation
            }
            let info = try metadata(url)
            guard info.st_mode & S_IFMT == S_IFREG, StorageIdentity(info) == file.identity else {
                throw StorageScanError.changedFile(file.relativePath)
            }
            return url
        }
    }
}
