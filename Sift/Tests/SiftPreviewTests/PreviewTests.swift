import DuckDBKit
import Foundation
import SiftCore
import TestSupport
import Testing

@testable import SiftEngine
@testable import SiftPreview

// The Quick Look preview, cell by cell. Every fixture is written by a throwaway in-memory DuckDB
// (parquet, gz, zst) or by hand (csv, tsv, json, ndjson), then read back through the same
// `PreviewEngine` the extension calls.

// MARK: - fixtures

private let salesSelect =
    "SELECT range + 1 AS order_id, ['West','Midwest','South','Northeast'][(range % 4) + 1] AS region, "
    + "(range * 1.5)::DECIMAL(12,2) AS amount, "
    + "CASE WHEN range % 3 = 0 THEN NULL ELSE 'note ' || range END AS note FROM range(ROWS)"

private func fixture(_ name: String, rows: Int, options: String) throws -> URL {
    let path = TestTemp.path("preview", "-" + name)
    let con = try Database.inMemory().connect()
    let sql = salesSelect.replacingOccurrences(of: "ROWS", with: String(rows))
    try con.execute("COPY (\(sql)) TO '\(path)' (\(options))")
    return URL(fileURLWithPath: path)
}

private func csv(rows: Int = 50) throws -> URL {
    try fixture("sales.csv", rows: rows, options: "FORMAT csv, HEADER")
}

private func textFile(_ name: String, _ text: String) throws -> URL {
    let path = TestTemp.path("preview", "-" + name)
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    return URL(fileURLWithPath: path)
}

private func table(_ model: PreviewModel) throws -> PreviewTable {
    guard case .table(let table) = model.state else {
        throw PreviewTestFailure("expected a table, got \(model.state)")
    }
    return table
}

private struct PreviewTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - formats

@Test func aCSVPreviewHasExactCountsTypesAndTheFirstRows() async throws {
    let model = await PreviewEngine.preview(url: try csv(rows: 50))
    let t = try table(model)
    #expect(model.rowCount == 50 && !model.rowsAreEstimate)
    #expect(model.columnCount == 4)
    #expect(t.columns.map(\.name) == ["order_id", "region", "amount", "note"])
    #expect(t.columns.map(\.type) == ["BIGINT", "VARCHAR", "DOUBLE", "VARCHAR"])
    #expect(t.rows.count == 50 && !t.moreRows)
    #expect(t.rows[1].map(\.text) == ["2", "Midwest", "1.5", "note 1"])
    #expect(model.headerFacts.first == "50 rows")
    #expect(model.headerFacts.contains("4 columns"))
    #expect(model.fileSize.map { $0 > 0 } == true)
}

@Test func numbersAlignRightAndNullsRenderTheWaySiftRendersThem() async throws {
    let t = try table(await PreviewEngine.preview(url: try csv()))
    #expect(t.columns.map(\.rightAligned) == [true, false, true, false])
    // Row 0 has note NULL: the word, styled as a null, not an empty cell.
    #expect(t.rows[0][3] == PreviewCell(text: nullGlyph, style: .null))
    #expect(t.rows[1][3].style == .normal)

    // NULL, '' and the text `null` are three different cells.
    let url = try textFile("nulls.csv", "id,v\n1,\n2,\"\"\n3,null\n4,N/A\n")
    let n = try table(await PreviewEngine.preview(url: url))
    #expect(n.rows.map { $0[1].style } == [.null, .empty, .normal, .normal])
    #expect(n.rows.map { $0[1].text } == ["null", "''", "null", "N/A"])
}

@Test func moreThanTwoHundredRowsStopsAtTwoHundredAndSaysThereAreMore() async throws {
    let model = await PreviewEngine.preview(url: try csv(rows: 1000))
    let t = try table(model)
    #expect(t.rows.count == previewMaxRows)
    #expect(t.moreRows)
    #expect(model.rowCount == 1000)
    // Exactly the cap is not "more".
    let exact = try table(await PreviewEngine.preview(url: try csv(rows: previewMaxRows)))
    #expect(exact.rows.count == previewMaxRows && !exact.moreRows)
}

@Test func longTextIsTruncatedWithAnEllipsisAndNeverMidCharacter() async throws {
    let long = String(repeating: "\u{00E9}", count: 500)
    let t = try table(await PreviewEngine.preview(url: try textFile("long.csv", "a,b\n1,\(long)\n")))
    let cell = t.rows[0][1].text
    #expect(cell.count == previewCellLimit)
    #expect(cell.hasSuffix("\u{2026}"))
    #expect(cell.dropLast().allSatisfy { $0 == "\u{00E9}" })
    #expect(truncatedCellText("short") == "short")
    #expect(truncatedCellText(String(repeating: "x", count: 120)).count == 120)
    #expect(truncatedCellText(String(repeating: "x", count: 121)).hasSuffix("\u{2026}"))
}

@Test func tabSeparatedAndCompressedFilesPreview() async throws {
    let tsv = try fixture("sales.tsv", rows: 30, options: "FORMAT csv, DELIMITER '\t', HEADER")
    let tsvModel = await PreviewEngine.preview(url: tsv)
    #expect(try table(tsvModel).columns.count == 4 && tsvModel.rowCount == 30)

    for (name, compression) in [("sales.csv.gz", "gzip"), ("sales.csv.zst", "zstd")] {
        let url = try fixture(name, rows: 30, options: "FORMAT csv, HEADER, COMPRESSION \(compression)")
        let (model, diagnostics) = await PreviewEngine.previewWithDiagnostics(url: url)
        #expect(try table(model).rows.count == 30, "\(name)")
        // A compressed file has no footer count and no estimate; the short page IS the file.
        #expect(model.rowCount == 30 && !model.rowsAreEstimate, "\(name)")
        #expect(diagnostics.networkInstalls.isEmpty, "\(name)")
    }
}

@Test func compressedFilesBeyondTheFirstPageAreCountedExactly() async throws {
    let url = try fixture("big.csv.gz", rows: 1000, options: "FORMAT csv, HEADER, COMPRESSION gzip")
    let model = await PreviewEngine.preview(url: url)
    #expect(try table(model).moreRows)
    #expect(model.rowCount == 1000 && !model.rowsAreEstimate)
}

@Test func parquetJSONAndNDJSONPreview() async throws {
    let parquet = await PreviewEngine.preview(url: try fixture("sales.parquet", rows: 500, options: "FORMAT parquet"))
    let p = try table(parquet)
    #expect(parquet.rowCount == 500 && parquet.columnCount == 4)
    #expect(p.columns.map(\.type) == ["BIGINT", "VARCHAR", "DECIMAL(12,2)", "VARCHAR"])
    #expect(p.rows.count == 200 && p.moreRows)
    #expect(p.rows[0][3].style == .null)

    let array = try textFile("a.json", "[{\"id\":1,\"name\":\"a\"},{\"id\":2,\"name\":null}]")
    let json = await PreviewEngine.preview(url: array)
    #expect(try table(json).rows.count == 2 && json.rowCount == 2)
    #expect(try table(json).rows[1][1].style == .null)

    let lines = try textFile("a.ndjson", "{\"id\":1}\n{\"id\":2}\n{\"id\":3}\n")
    let nd = await PreviewEngine.preview(url: lines)
    #expect(try table(nd).rows.count == 3 && nd.rowCount == 3)
}

@Test func aLargeCSVShowsSiftsEstimateAndLabelsIt() async throws {
    // Just past the 64 MiB exact-count ceiling, where Sift switches to a sampled estimate.
    let url = try fixture("huge.csv", rows: 3_000_000, options: "FORMAT csv, HEADER")
    #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0) > 64 * 1024 * 1024)
    let model = await PreviewEngine.preview(url: url, budget: 20)
    #expect(model.rowsAreEstimate)
    let rows = try #require(model.rowCount)
    #expect(abs(rows - 3_000_000) < 300_000)
    #expect(model.headerFacts.first?.hasSuffix("(estimate)") == true)
    #expect(try table(model).rows.count == previewMaxRows)
}

@Test func aVeryWideFileShowsTheFirstColumnsAndCountsTheRest() async throws {
    let header = (0..<260).map { "c\($0)" }.joined(separator: ",")
    let row = (0..<260).map(String.init).joined(separator: ",")
    let model = await PreviewEngine.preview(url: try textFile("wide.csv", header + "\n" + row + "\n"))
    let t = try table(model)
    #expect(t.columns.count == previewMaxColumns && t.hiddenColumns == 60)
    #expect(model.columnCount == 260)
}

// MARK: - what a preview must refuse

@Test func excelAndDeltaAreDeclinedWithoutOpeningADatabaseOrDownloadingAnything() async throws {
    // A zip with an .xlsx name: Sift would need the excel extension to read it.
    let xlsx = TestTemp.path("preview", "-book.xlsx")
    try Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0]).write(to: URL(fileURLWithPath: xlsx))
    let (book, bookDiag) = await PreviewEngine.previewWithDiagnostics(url: URL(fileURLWithPath: xlsx))
    guard case .declined(let sentence) = book.state else { throw PreviewTestFailure("xlsx: \(book.state)") }
    #expect(sentence.contains("Excel"))
    #expect(bookDiag == PreviewEngine.Diagnostics(openedDatabase: false, networkInstalls: []))

    let delta = TestTemp.dir("preview-delta")
    try FileManager.default.createDirectory(atPath: delta + "/_delta_log", withIntermediateDirectories: true)
    let (table, deltaDiag) = await PreviewEngine.previewWithDiagnostics(url: URL(fileURLWithPath: delta))
    guard case .declined = table.state else { throw PreviewTestFailure("delta: \(table.state)") }
    #expect(deltaDiag == PreviewEngine.Diagnostics(openedDatabase: false, networkInstalls: []))

    // A readable format opens a database but still issues no INSTALL.
    let (_, csvDiag) = await PreviewEngine.previewWithDiagnostics(url: try csv())
    #expect(csvDiag.openedDatabase && csvDiag.networkInstalls.isEmpty)
    // The real worker path, not a probe: the connection a preview read through was locked down.
    #expect(csvDiag.externalAccessEnabled == false)
    #expect(csvDiag.configurationLocked == true)
    #expect(csvDiag.memoryLimit?.contains("MiB") == true)
}

@Test func anUnreadableFileGetsOnePlainSentence() async throws {
    let bad = TestTemp.path("preview", "-bad.parquet")
    try Data("this is not parquet at all".utf8).write(to: URL(fileURLWithPath: bad))
    let model = await PreviewEngine.preview(url: URL(fileURLWithPath: bad))
    guard case .unreadable(let sentence) = model.state else { throw PreviewTestFailure("\(model.state)") }
    #expect(sentence.hasPrefix("Sift could not read this file. "))
    #expect(sentence.hasSuffix("."))
    #expect(!sentence.contains("\n") && !sentence.contains("Error:") && !sentence.contains(bad))
    #expect(model.fileName.hasSuffix("bad.parquet"))
    #expect(!sentence.contains("/"))

    let missing = await PreviewEngine.preview(url: URL(fileURLWithPath: TestTemp.path("preview", "-nope.csv")))
    guard case .unreadable(let again) = missing.state else { throw PreviewTestFailure("\(missing.state)") }
    #expect(again.hasPrefix("Sift could not read this file."))
}

// MARK: - the time budget

@Test func aSourceThatNeverAnswersGetsTheHeaderAndPreviewTookTooLong() async throws {
    // A named pipe nobody writes to: `open` for reading blocks forever, below DuckDB and below
    // anything interruptible. The preview must still come back on time.
    let fifo = TestTemp.path("preview", "-stuck.csv")
    #expect(mkfifo(fifo, 0o600) == 0)
    let started = Date()
    let model = await PreviewEngine.preview(url: URL(fileURLWithPath: fifo), budget: 0.4)
    let elapsed = Date().timeIntervalSince(started)
    #expect(model.state == .timedOut)
    #expect(model.fileName.hasSuffix("stuck.csv"))
    #expect(elapsed >= 0.4 && elapsed < 2.0, "took \(elapsed)s")
    #expect(renderPreviewHTML(model).contains("Preview took too long."))

    // Release the abandoned worker so the test process exits cleanly.
    let writer = open(fifo, O_WRONLY)
    if writer >= 0 { close(writer) }
}

@Test func ifTheRowsAreReadyWhenTheBudgetEndsTheRowsAreWhatIsShown() async throws {
    let url = try csv(rows: 20)
    let started = Date()
    let (model, _) = await PreviewEngine.previewWithDiagnostics(
        url: url, budget: 0.5, afterFirstRows: { Thread.sleep(forTimeInterval: 1.5) })
    #expect(try table(model).rows.count == 20)
    #expect(Date().timeIntervalSince(started) < 1.4)
}

// MARK: - read-only, no writes

@Test func aPreviewWritesNothingAndChangesNothing() async throws {
    let dir = TestTemp.dir("preview-readonly")
    let path = dir + "/sales.csv"
    try FileManager.default.copyItem(atPath: try csv(rows: 300).path, toPath: path)
    let before = try listing(dir)
    _ = await PreviewEngine.preview(url: URL(fileURLWithPath: path))
    #expect(try listing(dir) == before)
}

private func listing(_ dir: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir).sorted().map { name in
        let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/" + name)
        return "\(name):\(attrs[.size] ?? 0):\(attrs[.modificationDate] ?? "")"
    }
}

@Test func theLockdownAllowsTheOneFileAndNothingElse() throws {
    let allowed = try csv().path
    let other = try csv().path
    let outside = TestTemp.path("preview", "-written.csv")

    let db = try Database.inMemory()
    db.harden()
    let con = try db.connect()
    for sql in PreviewEngine.lockdownStatements(allowedPath: allowed) { try con.execute(sql) }

    #expect(try con.query("SELECT count(*) FROM read_csv('\(allowed)')").allRows() == [[.int(50)]])
    // Any other file, any write, any reconfiguration, any extension: refused.
    #expect(throws: DuckDBError.self) { try con.query("SELECT * FROM read_csv('\(other)')").allRows() }
    #expect(throws: DuckDBError.self) { try con.execute("COPY (SELECT 1) TO '\(outside)'") }
    #expect(throws: DuckDBError.self) { try con.execute("SET enable_external_access=true") }
    #expect(throws: DuckDBError.self) { try con.execute("SET allowed_paths=['\(other)']") }
    #expect(throws: DuckDBError.self) { try con.execute("INSTALL httpfs") }
    #expect(throws: DuckDBError.self) { try con.execute("LOAD httpfs") }
    #expect(throws: DuckDBError.self) { try con.execute("ATTACH '\(outside).db' AS x") }
    #expect(!FileManager.default.fileExists(atPath: outside))
}

// MARK: - the page

@Test func theHTMLEscapesCellsAndCarriesNoScriptOrRemoteReference() async throws {
    let url = try textFile("evil.csv", "name\n<script>alert(1)</script>\n\"&'\"\n")
    let model = await PreviewEngine.preview(url: url)
    let html = renderPreviewHTML(model)
    #expect(!html.contains("<script"))
    #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    #expect(html.contains("Content-Security-Policy"))
    #expect(html.contains("default-src 'none'"))
    #expect(!html.contains("http://") && !html.contains("https://"))
    #expect(html.contains("-evil.csv</title>"))
}

@Test func theHTMLFollowsAppearanceAndAlignsNumbers() async throws {
    let model = await PreviewEngine.preview(url: try csv())
    #expect(renderPreviewHTML(model).contains("prefers-color-scheme:dark"))
    #expect(renderPreviewHTML(model).contains("<html lang=\"en\">"))
    #expect(renderPreviewHTML(model, appearance: .dark).contains("data-theme=\"dark\""))
    #expect(renderPreviewHTML(model, appearance: .light).contains("data-theme=\"light\""))
    #expect(renderPreviewHTML(model).contains("<th class=\"r\">"))
    #expect(renderPreviewHTML(model).contains("position:sticky;top:0"))
    #expect(renderPreviewHTML(model).contains("tabular-nums"))
}

@Test func headerFactsReadNaturally() {
    let exact = PreviewModel(fileName: "a.csv", fileSize: 1_234_567, rowCount: 1_234, columnCount: 3, state: .timedOut)
    #expect(exact.headerFacts == ["1,234 rows", "3 columns", "1.23 MB"])
    let estimate = PreviewModel(fileName: "a.csv", fileSize: 999, rowCount: 5_000_000, rowsAreEstimate: true, columnCount: 1, state: .timedOut)
    #expect(estimate.headerFacts == ["about 5,000,000 rows (estimate)", "1 column", "999 bytes"])
    let one = PreviewModel(fileName: "a.csv", rowCount: 1, state: .timedOut)
    #expect(one.headerFacts == ["1 row"])
    #expect(formatFileSize(12_345) == "12.3 KB" && formatFileSize(2_000_000_000) == "2.00 GB")
}
