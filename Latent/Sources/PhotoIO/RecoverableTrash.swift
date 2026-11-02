import Foundation

/// The UI retains these receipts; moving back never replaces an existing destination.
public struct RecoverableTrash: Sendable {
    public struct Receipt: Sendable {
        public let originalURL: URL
        public let trashURL: URL?
    }

    private let moveToTrash: @Sendable (URL) throws -> URL?

    public init(moveToTrash: @escaping @Sendable (URL) throws -> URL? = Self.systemTrash) {
        self.moveToTrash = moveToTrash
    }

    public func trash(_ url: URL) throws -> Receipt {
        Receipt(originalURL: url, trashURL: try moveToTrash(url))
    }

    public func restore(originalURL: URL, trashURL: URL) throws {
        // moveItem fails if anything already occupies originalURL, including a symlink.
        try FileManager.default.moveItem(at: trashURL, to: originalURL)
    }

    public static func systemTrash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}
