import DuckDBKit
import Foundation
import SiftCore
import SiftEngine

// Opens one data file read-only and returns what a Quick Look preview shows.
//
// Why not `Session`: a session owns `~/.sift`, a staged-data store, a Keychain service and a
// connections file. A preview needs none of them and must write nothing, so it gets a bare
// in-memory `Database` instead, hardened like every other one and then locked down further (below).
//
// The time budget is a RACE, not a hope. The work runs on its own thread; the caller waits on a
// timer. When the timer wins, the caller gets an answer anyway (the first rows if they were ready,
// "took too long" if not) and the worker is interrupted and abandoned. A worker blocked in a
// system call (a pipe nobody writes to, a stalled network volume) can therefore never hang Finder.

public enum PreviewEngine {
    /// The wall-clock budget for a whole preview.
    public static let defaultBudget: TimeInterval = 2.0
    /// DuckDB's own ceiling. The extension process is small and Quick Look kills one that grows.
    public static let memoryLimit = "256MB"

    public static func preview(
        url: URL, budget: TimeInterval = defaultBudget,
        maxRows: Int = previewMaxRows, maxColumns: Int = previewMaxColumns
    ) async -> PreviewModel {
        await previewWithDiagnostics(url: url, budget: budget, maxRows: maxRows, maxColumns: maxColumns).model
    }

    /// What the preview DID, for tests to assert, beside what it shows.
    public struct Diagnostics: Sendable, Equatable {
        /// `false` for every format the preview declines: no DuckDB exists, so nothing can install.
        public var openedDatabase = false
        /// Every extension an `INSTALL` was issued for: the only outbound request the engine can
        /// make. Always empty; a test holds it there.
        public var networkInstalls: [String] = []
        /// The connection's settings as the worker saw them after the lockdown ran, read back from
        /// DuckDB itself: external access off, configuration locked, the memory ceiling.
        public var externalAccessEnabled: Bool?
        public var configurationLocked: Bool?
        public var memoryLimit: String?
    }

    /// `afterFirstRows` is a test seam: it runs on the worker once the first rows are published,
    /// so a test can stall the slow tail of a preview deterministically.
    public static func previewWithDiagnostics(
        url: URL, budget: TimeInterval = defaultBudget,
        maxRows: Int = previewMaxRows, maxColumns: Int = previewMaxColumns,
        afterFirstRows: (@Sendable () -> Void)? = nil
    ) async -> (model: PreviewModel, diagnostics: Diagnostics) {
        let job = PreviewJob(path: url.path, maxRows: maxRows, maxColumns: maxColumns, afterFirstRows: afterFirstRows)
        let model = await job.run(budget: budget)
        return (model, job.diagnostics)
    }

    /// Everything the preview does to a `Database` before it reads a byte, as SQL. Public so a
    /// test can run exactly these statements against a probe database.
    ///
    /// `enable_external_access=false` with an allow-list of the one file is the read-only,
    /// no-network, no-write guarantee in one setting: nothing but that path can be opened, nothing
    /// can be created (temp spill files included) and no extension can be loaded or installed.
    /// `lock_configuration` then stops any later statement from undoing it.
    public static func lockdownStatements(allowedPath: String) -> [String] {
        [
            "SET threads=2",
            "SET memory_limit='\(memoryLimit)'",
            "SET allowed_paths=[\(qlit(allowedPath))]",
            "SET enable_external_access=false",
            "SET lock_configuration=true",
        ]
    }
}

/// One preview in flight. `@unchecked Sendable`: every mutable field is behind `lock`.
final class PreviewJob: @unchecked Sendable {
    let path: String
    let maxRows: Int
    let maxColumns: Int
    private let lock = NSLock()
    private var partial: PreviewModel?
    private var connection: Connection?
    // `Connection` does not retain its `Database`; the timer thread may still interrupt the
    // connection after `build()` returns, so the job owns the database.
    private var database: Database?
    private var cancelled = false
    private var continuation: CheckedContinuation<PreviewModel, Never>?
    private var delivered = false
    private let baseName: String
    private let size: Int64?

    private var diag = PreviewEngine.Diagnostics()
    var diagnostics: PreviewEngine.Diagnostics { lock.withLock { diag } }
    private let afterFirstRows: (@Sendable () -> Void)?

    init(path: String, maxRows: Int, maxColumns: Int, afterFirstRows: (@Sendable () -> Void)? = nil) {
        self.afterFirstRows = afterFirstRows
        self.path = path
        self.maxRows = maxRows
        self.maxColumns = maxColumns
        baseName = (path as NSString).lastPathComponent
        var st = stat()
        size = stat(path, &st) == 0 ? Int64(st.st_size) : nil
    }

    func run(budget: TimeInterval) async -> PreviewModel {
        await withCheckedContinuation { (cont: CheckedContinuation<PreviewModel, Never>) in
            lock.lock()
            continuation = cont
            lock.unlock()
            let worker = Thread { [self] in
                let result = work()
                deliver(result)
            }
            worker.stackSize = 8 * 1024 * 1024
            worker.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + budget) { [self] in
                lock.lock()
                cancelled = true
                let answer = partial ?? PreviewModel(fileName: baseName, fileSize: size, state: .timedOut)
                let con = connection
                lock.unlock()
                // `duckdb_interrupt` before execution starts is swallowed (AGENTS.md), so keep at
                // it briefly; the abandoned worker then stops instead of burning CPU in Finder's
                // extension host.
                // Answer first: the caller is waiting on the budget, the abandoned worker is not.
                deliver(answer)
                if let con { for _ in 0..<20 { con.interrupt(); usleep(10_000) } }
            }
        }
    }

    private func deliver(_ model: PreviewModel) {
        lock.lock()
        guard !delivered, let cont = continuation else { lock.unlock(); return }
        delivered = true
        continuation = nil
        lock.unlock()
        cont.resume(returning: model)
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }
    private func publish(_ model: PreviewModel) { lock.withLock { partial = model } }

    private func plain(_ state: PreviewState) -> PreviewModel {
        PreviewModel(fileName: baseName, fileSize: size, state: state)
    }

    /// The worker body. Never throws: every failure is one sentence in the model.
    private func work() -> PreviewModel {
        do {
            return try build()
        } catch let error as LegacyXls {
            return plain(.declined(error.message))
        } catch let error as UnsupportedSource {
            return plain(.unreadable(sentence(error.message)))
        } catch let error as DuckDBError {
            if isCancelled { return plain(.timedOut) }
            return plain(.unreadable(sentence(error.firstLine)))
        } catch {
            return plain(.unreadable(sentence(error.localizedDescription)))
        }
    }

    private func sentence(_ text: String) -> String {
        var line = text.split(separator: "\n").first.map(String.init) ?? text
        line = line.trimmingCharacters(in: .whitespaces)
        if let colon = line.range(of: " Error: ") { line = String(line[colon.upperBound...]) }
        // DuckDB quotes the path it failed on; the file is already named in the header.
        line = line.replacingOccurrences(of: "\\s*'[^']*/[^']*'", with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: "[\\s:]+$", with: "", options: .regularExpression)
        line = String(line.prefix(240))
        if let first = line.first, first.isLowercase { line = first.uppercased() + line.dropFirst() }
        if !line.hasSuffix(".") { line += "." }
        return "Sift could not read this file. " + line
    }

    private func build() throws -> PreviewModel {
        let resolved = realpathString(path)
        // The format decision comes first and is purely local: an Excel workbook or a Delta table
        // needs a DuckDB extension that may not be installed, and a preview must never download
        // one. Declining here means no `Database` exists yet, so there is nothing to install with.
        let fmt = try detectFormat(resolved)
        switch fmt {
        case .xlsx:
            return plain(.declined("Excel workbooks open in Sift, not in Quick Look."))
        case .delta, .globParquet, .globCsv, .merge:
            return plain(.declined("Folders open in Sift, not in Quick Look."))
        case .csv, .parquet, .json, .ndjson:
            break
        }

        let db = try Database.inMemory()
        lock.withLock { diag.openedDatabase = true }
        defer { let installs = db.networkInstalls; lock.withLock { diag.networkInstalls = installs } }
        db.harden()
        let con = try db.connect()
        lock.withLock { connection = con; database = db }
        // Locked down before the first read: from here the connection can open this one file and
        // nothing else, create nothing, and cannot be reconfigured.
        for sql in PreviewEngine.lockdownStatements(allowedPath: resolved) { try con.execute(sql) }
        let settings = try con.query(
            "SELECT current_setting('enable_external_access'), current_setting('lock_configuration'), "
                + "current_setting('memory_limit')"
        ).allRows()
        if let row = settings.first, row.count == 3 {
            lock.withLock {
                diag.externalAccessEnabled = row[0].display == "true"
                diag.configurationLocked = row[1].display == "true"
                diag.memoryLimit = row[2].display
            }
        }
        if isCancelled { return plain(.timedOut) }

        let spec = try buildSource(con, path: resolved)
        let total = spec.columns.count
        let shown = Array(spec.columns.prefix(maxColumns))
        let columns = shown.map { PreviewColumn(name: $0.name, type: $0.type, kind: $0.kind) }

        // One extra row tells "exactly maxRows" from "more than maxRows".
        let select = shown.map { q($0.name) }.joined(separator: ", ")
        let from = readExpr(spec: spec)
        let result = try con.query("SELECT \(select) FROM \(from) LIMIT \(maxRows + 1)").allRows()
        let more = result.count > maxRows
        let rows = result.prefix(maxRows).map { row in
            zip(row, shown).map { previewCell($0, kind: $1.kind) }
        }
        let table = PreviewTable(columns: columns, rows: Array(rows), hiddenColumns: total - shown.count, moreRows: more)

        // A short result IS the whole file, so its count is exact whatever the format.
        var count = spec.rowCount
        var estimate = false
        if count == nil, !more { count = result.count }
        if count == nil, let est = spec.rowEstimate { count = est.rows; estimate = true }
        func model(_ count: Int?, _ estimate: Bool) -> PreviewModel {
            PreviewModel(
                fileName: baseName, fileSize: size, rowCount: count, rowsAreEstimate: estimate,
                columnCount: total, state: .table(table))
        }
        publish(model(count, estimate))
        afterFirstRows?()

        // A compressed file has neither a footer count nor an estimate. Count it if the budget
        // allows; if it does not, the rows above were already published and are what is shown.
        if count == nil {
            let exact = try exactCount(con, spec: spec)
            return model(exact, false)
        }
        return model(count, estimate)
    }

    private func realpathString(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
