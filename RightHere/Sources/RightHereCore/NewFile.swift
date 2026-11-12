import Foundation
import Darwin

public enum NewFileError: LocalizedError, Equatable {
    case failed(Int32)
    case exhausted
    public var errorDescription: String? {
        switch self {
        case .failed(let code): return String(cString: strerror(code))
        case .exhausted: return "No free name was found."
        }
    }
}

/// The only file operation in RightHere: create an empty file with a name that is not taken.
public enum NewFile {
    public static let maximumAttempts = 10_000

    /// `untitled.ext`, then `untitled 2.ext`, `untitled 3.ext` and so on. An empty extension gives `untitled`.
    public static func name(number: Int, ext: String) -> String {
        let stem = number <= 1 ? "untitled" : "untitled \(number)"
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// Creates the file with O_CREAT | O_EXCL, so the kernel refuses a name that already exists
    /// (even one made a moment ago, or differing only in case on a case-insensitive volume).
    /// Nothing is ever overwritten, moved or deleted; any other error stops with nothing created.
    public static func create(in folder: URL, ext: String) throws -> URL {
        for number in 1...maximumAttempts {
            let url = folder.appendingPathComponent(name(number: number, ext: ext), isDirectory: false)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o666)
            if descriptor >= 0 {
                close(descriptor)
                return url
            }
            if errno == EEXIST { continue }
            throw NewFileError.failed(errno)
        }
        throw NewFileError.exhausted
    }
}
