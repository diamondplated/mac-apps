import Foundation

/// Why a video file could not be opened. Codec problems are not errors: a
/// track AVFoundation cannot decode is skipped and reported on the movie.
public enum ContainerError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreadable(Int32)
    /// Neither Matroska nor AVI.
    case unrecognized
    case unsupportedDocType(String)
    case noSegment
    /// An AVI file without a movie list.
    case noMovieData
    case noPlayableTracks([String])

    public var description: String {
        switch self {
        case .unreadable(let code):
            return "The file could not be read (\(String(cString: strerror(code))))."
        case .unrecognized:
            return "This is not a Matroska or AVI file."
        case .unsupportedDocType(let docType):
            return "Unsupported Matroska document type “\(docType)”."
        case .noSegment:
            return "The file has no Matroska segment."
        case .noMovieData:
            return "The AVI file has no movie data."
        case .noPlayableTracks(let reasons):
            if reasons.isEmpty { return "The file contains no video or audio tracks." }
            return "None of this file's tracks can be played on macOS: " + reasons.joined(separator: "; ") + "."
        }
    }
}
