import Testing
import Foundation
import TestSupport
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

@Test(.engineLifetime) func completionStrictHardeningFailureRefusesSessionAndReleasesHome() throws {
    let home = TestTemp.path("hardening-refusal")
    #expect(throws: SessionError.self) {
        _ = try Session(home: home, keychainService: "test-unused", hardening: { db, _ in
            db.harden()
            var outcomes = db.hardened
            // A real failed SET, represented exactly as Database.harden represents failures.
            outcomes["disabled_filesystems"] = (try? db.connect().execute("SET no_such_setting=true")) != nil
            return outcomes
        })
    }
    let session = try Session(home: home)
    #expect(session.sharedStore)
}

@Test(.engineLifetime) func completionTempTableProbePropagatesQueryErrors() async throws {
    let session = try Session(home: TestTemp.path("temp-probe"))
    do {
        _ = try await session.tempTableExistsForTest("absent", query: "SELECT * FROM missing_relation WHERE name = ?")
        Issue.record("A failed query must not be interpreted as an absent temporary table")
    } catch is DuckDBError { }
    #expect(try await !session.tempTableExistsForTest("absent"))
}

@Test(.engineLifetime) func completionOwnerSweepPreservesFallbackCache() throws {
    let home = TestTemp.dir("fallback-cache")
    let session = try Session(home: home)
    let url = try #require(classifyRemote("https://example.invalid/data.csv"))
    let path = try remoteCachePath(home: home, url: url, owner: ProcessInfo.processInfo.processIdentifier)
    try Data("a\n1\n".utf8).write(to: URL(fileURLWithPath: path))
    let shared = try remoteCachePath(home: home, url: url)
    #expect(path != shared)
    Session.sweepRemoteCache(in: home, con: try session.database.connect(), sharedStore: true)
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "a\n1\n")
}

@Test(.engineLifetime, arguments: [false, true])
func completionStagingMetadataFailureKeepsOriginalView(recordFailure: Bool) async throws {
    let home = TestTemp.dir("stage-metadata")
    let source = try makeCSV(dir: home, rows: 10)
    let session = try Session(home: (home as NSString).appendingPathComponent("store"))
    let table = try await session.openPath(source)
    // Remove the query's dependency inside the swap transaction: the actual count/INSERT
    // fails, and rollback must restore both the original view and metadata catalog.
    let failure: (Connection) throws -> Void = { con in
        try con.execute(recordFailure ? "DROP TABLE _sift_sources" : "DROP TABLE \(q(table.name))")
    }
    await session.runStage(name: table.name, spec: table.spec, jobID: "fault", job: StageJob(),
                           openedAt: table.openedAt,
                           beforeCount: recordFailure ? nil : failure,
                           beforeRecord: recordFailure ? failure : nil)
    let after = try await session.table(table.name)
    #expect(!after.staged)
    #expect(after.stagingError?.hasPrefix("staging failed:") == true)
    let con = try session.database.connect()
    #expect(try con.query("SELECT count(*) FROM \(q(table.name))").allRows() == [[.int(10)]])
    #expect(try con.query("SELECT count(*) FROM duckdb_views() WHERE view_name = ?", [.text(table.name)]).allRows() == [[.int(1)]])
    #expect(try await session.stagedEntries().isEmpty)
}

@Test(.engineLifetime) func completionDeadPrivateStoreSweepRemovesOnlyItsOwnCache() throws {
    let home = TestTemp.dir("dead-private-cache")
    let url = try #require(classifyRemote("https://example.invalid/data.csv"))
    let dead: Int32 = .max
    let alive = ProcessInfo.processInfo.processIdentifier
    for pid in [dead, alive] {
        let store = (home as NSString).appendingPathComponent("stage-\(pid).duckdb")
        try Data().write(to: URL(fileURLWithPath: store))
        let cache = try remoteCachePath(home: home, url: url, owner: pid)
        try Data("a\n1\n".utf8).write(to: URL(fileURLWithPath: cache))
    }
    Session.sweepPrivateStores(in: home)
    let root = (home as NSString).appendingPathComponent(remoteCacheDirName)
    #expect(!FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("stage-\(dead)")))
    #expect(FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("stage-\(alive)")))
}

@Test(.engineLifetime) func completionPrivateCacheCleanupDoesNotTraverseParentSymlink() throws {
    let home = TestTemp.dir("private-cache-link")
    let outside = TestTemp.dir("outside-private-cache")
    let sentinel = (outside as NSString).appendingPathComponent("stage-123")
    try FileManager.default.createDirectory(atPath: sentinel, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: URL(fileURLWithPath: sentinel).appendingPathComponent("photo"))
    try FileManager.default.createSymbolicLink(atPath: (home as NSString).appendingPathComponent(remoteCacheDirName), withDestinationPath: outside)
    Session.removePrivateCache(in: home, pid: 123)
    #expect(FileManager.default.fileExists(atPath: (sentinel as NSString).appendingPathComponent("photo")))
}

@Test(.engineLifetime) func completionSuccessfulStagingRecordsPositiveBytes() async throws {
    let home = TestTemp.dir("stage-bytes")
    let source = try makeCSV(dir: home, rows: 1000)
    let session = try Session(home: (home as NSString).appendingPathComponent("store"))
    let table = try await session.openPath(source)
    await session.runStage(name: table.name, spec: table.spec, jobID: "bytes", job: StageJob(), openedAt: table.openedAt)
    let after = try await session.table(table.name)
    #expect(after.staged)
    #expect(after.stagingError == nil)
    let rows = try session.database.connect().query("SELECT bytes, row_count FROM _sift_sources WHERE table_name = ?", [.text(table.name)]).allRows()
    let row = try #require(rows.first)
    #expect(cellInt(row[0]) > 0)
    #expect(cellInt(row[1]) == 1000)
}
