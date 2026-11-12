import DuckDBKit
import Foundation
import SiftCore
import SiftEngine

// What the Quick Look preview shows, as plain values. No DuckDB handle, no view: this is the part a
// test can read cell by cell, and the part the HTML renderer and the `sift --preview` command both
// consume, so the extension and the command line cannot disagree about what a file looks like.

/// How one cell is drawn. Kept apart from the text because `null` the word and NULL the value are
/// different facts (a text cell can literally say `null`), and the page dims only the second.
public enum PreviewCellStyle: Sendable, Equatable {
    case normal
    /// SQL NULL: the value was never there.
    case null
    /// The empty string: something was written, and it was nothing.
    case empty
}

public struct PreviewCell: Sendable, Equatable {
    public let text: String
    public let style: PreviewCellStyle

    public init(text: String, style: PreviewCellStyle = .normal) {
        self.text = text
        self.style = style
    }
}

public struct PreviewColumn: Sendable, Equatable {
    public let name: String
    public let type: String
    public let kind: Kind
    /// Numbers are right-aligned, everything else left.
    public var rightAligned: Bool { kind == .number }

    public init(name: String, type: String, kind: Kind) {
        self.name = name
        self.type = type
        self.kind = kind
    }
}

public struct PreviewTable: Sendable, Equatable {
    public let columns: [PreviewColumn]
    public let rows: [[PreviewCell]]
    /// Columns the file has beyond the ones shown; `0` for everything but a very wide file.
    public let hiddenColumns: Int
    /// `true` when the file has more rows than `rows` holds.
    public let moreRows: Bool

    public init(columns: [PreviewColumn], rows: [[PreviewCell]], hiddenColumns: Int = 0, moreRows: Bool = false) {
        self.columns = columns
        self.rows = rows
        self.hiddenColumns = hiddenColumns
        self.moreRows = moreRows
    }
}

public enum PreviewState: Sendable, Equatable {
    case table(PreviewTable)
    /// The time budget ran out before the first rows were ready.
    case timedOut
    /// A format a preview must not open, with the one sentence that says why.
    case declined(String)
    /// The file could not be read, with the one sentence that says why.
    case unreadable(String)
}

public struct PreviewModel: Sendable, Equatable {
    public let fileName: String
    public let fileSize: Int64?
    /// Exact when `rowsAreEstimate` is `false`; Sift's own sampled estimate when it is `true`;
    /// `nil` when neither was available inside the budget.
    public let rowCount: Int?
    public let rowsAreEstimate: Bool
    public let columnCount: Int?
    public let state: PreviewState

    public init(
        fileName: String, fileSize: Int64? = nil, rowCount: Int? = nil, rowsAreEstimate: Bool = false,
        columnCount: Int? = nil, state: PreviewState
    ) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.rowCount = rowCount
        self.rowsAreEstimate = rowsAreEstimate
        self.columnCount = columnCount
        self.state = state
    }

    /// The header's facts in the order they are drawn: rows, columns, size. Each is its own string
    /// so the page can space them and a test can read them.
    public var headerFacts: [String] {
        var facts: [String] = []
        if let rowCount {
            let digits = groupDigits(String(rowCount))
            if rowsAreEstimate {
                facts.append("about \(digits) rows (estimate)")
            } else {
                facts.append(rowCount == 1 ? "1 row" : "\(digits) rows")
            }
        }
        if let columnCount { facts.append(columnCount == 1 ? "1 column" : "\(groupDigits(String(columnCount))) columns") }
        if let fileSize { facts.append(formatFileSize(fileSize)) }
        return facts
    }
}

// MARK: - the small formatters

/// `12.3 KB`, decimal units like Finder. Hand-rolled with `String(format:)`, which is POSIX:
/// `ByteCountFormatter` follows the user's locale, and AGENTS.md bans locale formatters in anything
/// a person reads (four locale bugs shipped that way).
public func formatFileSize(_ bytes: Int64) -> String {
    if bytes < 1000 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
    var value = Double(bytes)
    for unit in ["KB", "MB", "GB", "TB"] {
        value /= 1000
        if value < 1000 || unit == "TB" {
            let format = value < 10 ? "%.2f %@" : (value < 100 ? "%.1f %@" : "%.0f %@")
            return String(format: format, value, unit)
        }
    }
    return "\(bytes) bytes"
}

/// Cut a cell to `limit` characters, adding an ellipsis. Counts `Character`s, so an emoji or an
/// accented letter is never split in half.
public func truncatedCellText(_ text: String, limit: Int = previewCellLimit) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit - 1)) + "\u{2026}"
}

public let previewCellLimit = 120
public let previewMaxRows = 200
public let previewMaxColumns = 200

/// One value as the preview draws it: Sift's own glyph rules (`glyph(for:kind:)`), so a preview and
/// the app never disagree about a NULL, an empty string or a decimal, then cut to a readable width.
func previewCell(_ cell: Cell, kind: Kind) -> PreviewCell {
    if cell.isNull { return PreviewCell(text: nullGlyph, style: .null) }
    if case .text(let text) = cell, text.isEmpty { return PreviewCell(text: emptyStringGlyph, style: .empty) }
    let text = glyph(for: cell, kind: kind)
        .replacingOccurrences(of: "\n", with: " \u{23CE} ")
        .replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: "\t", with: " ")
    return PreviewCell(text: truncatedCellText(text))
}
