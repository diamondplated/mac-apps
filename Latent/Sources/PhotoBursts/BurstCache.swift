import Foundation
import CryptoKit

/// A file's identity and modification date. A cached signature is valid only
/// while all three still match, so an edited, replaced or swapped file is
/// recomputed rather than trusted.
public struct FileStamp: Codable, Sendable, Equatable {
    public var inode: UInt64
    public var size: UInt64
    public var modified: Double

    public init(inode: UInt64, size: UInt64, modified: Double) {
        self.inode = inode
        self.size = size
        self.modified = modified
    }

    public static func read(_ url: URL) -> FileStamp? {
        var info = stat()
        guard url.path.withCString({ stat($0, &info) }) == 0 else { return nil }
        let t = info.st_mtimespec
        return FileStamp(
            inode: UInt64(info.st_ino),
            size: UInt64(info.st_size),
            modified: Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
        )
    }
}

public struct StampedSignature: Codable, Sendable, Equatable {
    public var stamp: FileStamp
    public var signature: PhotoSignature
    public init(stamp: FileStamp, signature: PhotoSignature) {
        self.stamp = stamp
        self.signature = signature
    }
}

/// Per-folder store of signatures, one property-list file in the app's
/// support folder next to the search indices. Keys are paths relative to the
/// folder so renaming the parent keeps the cache useful.
public struct BurstCache: Sendable {
    public let fileURL: URL
    let header: Header

    struct Header: Codable, Equatable {
        var version: Int
        var algorithm: Int
        var printRevision: Int
    }

    struct File: Codable {
        var header: Header
        var folderPath: String
        var entries: [String: StampedSignature]
    }

    static let formatVersion = 1

    /// `directory` is injectable for tests and for isolated runs. Without
    /// one, `LATENT_BURST_CACHE_DIRECTORY` or the app support folder is used.
    public init(folder: URL, directory: URL? = nil) throws {
        let base: URL
        if let directory {
            base = directory
        } else if let override = ProcessInfo.processInfo.environment["LATENT_BURST_CACHE_DIRECTORY"],
                  override.hasPrefix("/") {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("photo-viewer/BurstCache", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.fileURL = base.appendingPathComponent("\(hash).plist")
        self.header = Header(
            version: Self.formatVersion,
            algorithm: BurstSignatureExtractor.algorithmVersion,
            printRevision: BurstSignatureExtractor.printRevision
        )
        self.folderPath = folder.standardizedFileURL.path
    }

    let folderPath: String

    /// Entries keyed by relative path; empty when there is no usable file
    /// (missing, corrupt, other version, other Vision revision).
    public func load() -> [String: StampedSignature] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? PropertyListDecoder().decode(File.self, from: data),
              file.header == header, file.folderPath == folderPath else { return [:] }
        return file.entries
    }

    public func save(_ entries: [String: StampedSignature]) {
        let file = File(header: header, folderPath: folderPath, entries: entries)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func relativePath(of url: URL) -> String {
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
