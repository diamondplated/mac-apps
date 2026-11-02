import Foundation
import Testing
import TestSupport
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

private let consentRemoteFacts = ProcessInfo.processInfo.environment["SIFT_REMOTE_FACTS"] == "1"

private func coldConsentSession(repository: String?) throws -> Session {
    let directory = TestTemp.dir("consent-extensions")
    return try Session(home: TestTemp.path("consent-home"), keychainService: "unused-consent-tests", hardening: { db, remote in
        do {
            let con = try db.connect()
            try con.execute("SET extension_directory=\(qlit(directory))")
            if let repository { try con.execute("SET custom_extension_repository=\(qlit(repository))") }
            db.harden(allowRemote: remote)
            return db.hardened
        } catch {
            Issue.record("Could not configure isolated extension test: \(error)")
            return [:]
        }
    })
}

private func consentSource(_ name: String) throws -> String {
    if name == "excel" { return siftCoreTestsFixture("book.xlsx") }
    let dir = TestTemp.dir("consent-delta")
    try FileManager.default.createDirectory(atPath: (dir as NSString).appendingPathComponent("_delta_log"), withIntermediateDirectories: true)
    return dir
}

@Test(.engineLifetime, arguments: ["excel", "delta"])
func extensionConsentEngineColdStartupAndFirstUseNeverInstall(_ name: String) async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    let session = try coldConsentSession(repository: server.baseURL)
    #expect(session.database.networkInstalls.isEmpty)
    #expect(server.requestLog.isEmpty)
    let path = try consentSource(name)
    do {
        _ = try await session.openPath(path)
        Issue.record("A missing file extension must require approval before opening")
    } catch let error as SessionError {
        let request = try #require(error.extensionDownload)
        #expect(request.extensionName == name)
        #expect(request.sourcePath == realPath(path))
        #expect(renderCLIError(error).contains("--allow-extension-download"))
    }
    #expect(session.database.networkInstalls.isEmpty)
    #expect(server.requestLog.isEmpty)
    #expect(await session.state().tables.isEmpty)
}

@Test(.engineLifetime, .enabled(if: consentRemoteFacts))
func remoteFactConsentFailedApprovedDownloadIsOneSentence() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    let session = try coldConsentSession(repository: server.baseURL)
    let request = try #require(try await session.requiredExtension(for: siftCoreTestsFixture("book.xlsx")))
    do {
        try await session.downloadExtension(request)
        Issue.record("The loopback repository has no extension binary")
    } catch let error as SessionError {
        #expect(error.message == "Sift could not download or load the DuckDB excel extension; check your connection and try again.")
        #expect(error.extensionDownload == nil)
    }
    #expect(session.database.networkInstalls == ["excel"])
    #expect(!server.requestLog.isEmpty)
    #expect(!session.allowRemoteAtLaunch)
}

@Test(.engineLifetime) func extensionConsentEngineChangedSourceCannotAuthorizeDifferentExtension() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    let session = try coldConsentSession(repository: server.baseURL)
    let path = (TestTemp.dir("consent-replaced") as NSString).appendingPathComponent("book.xlsx")
    try FileManager.default.copyItem(atPath: siftCoreTestsFixture("book.xlsx"), toPath: path)
    let request = try #require(try await session.requiredExtension(for: path))
    try FileManager.default.removeItem(atPath: path)
    try FileManager.default.createDirectory(atPath: (path as NSString).appendingPathComponent("_delta_log"), withIntermediateDirectories: true)
    do {
        try await session.downloadExtension(request)
        Issue.record("Approval for excel must not authorize delta after the source changes")
    } catch is SessionError { }
    #expect(session.database.networkInstalls.isEmpty)
    #expect(server.requestLog.isEmpty)
}

@Test(.engineLifetime) func extensionConsentEngineCLIRequiresExplicitFlagAndRejectsVerifyCombination() {
    #expect(parseArguments(["book.xlsx"]) == .open(path: "book.xlsx", sheet: nil, rows: 10, width: 100, nullPadding: false, skipPreamble: true))
    #expect(parseArguments(["book.xlsx", "--allow-extension-download"]) == .open(path: "book.xlsx", sheet: nil, rows: 10, width: 100, nullPadding: false, skipPreamble: true, allowExtensionDownload: true))
    #expect(parseArguments(["--verify", "--allow-extension-download"]) == .usageError("--verify takes no other arguments"))
    #expect(parseArguments(["book.xlsx", "--allow-extension-download=false"]) == .usageError("--allow-extension-download takes no value"))
}

@Test(.engineLifetime) func extensionConsentEngineAuditSnapshotsAreSafeDuringConcurrentLoads() async throws {
    let db = try Database.inMemory()
    db.harden()
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<32 {
            group.addTask {
                db.loadExtensions(["invalid;\(i)"], installMissing: false)
                for _ in 0..<20 {
                    _ = db.loadedExtensions
                    _ = db.networkInstalls
                    _ = db.hardened
                }
            }
        }
    }
    #expect(db.loadedExtensions.count == 32)
    #expect(db.loadedExtensions.values.allSatisfy { $0 == .rejectedName })
    #expect(db.networkInstalls.isEmpty)
}

@Test(.engineLifetime, .enabled(if: consentRemoteFacts))
func remoteFactConsentExplicitApprovalInstallsOnlyTheRequiredExtensionAndOpens() async throws {
    let session = try coldConsentSession(repository: nil)
    #expect(session.database.networkInstalls.isEmpty)
    let path = siftCoreTestsFixture("book.xlsx")
    let request = try #require(try await session.requiredExtension(for: path))
    try await session.downloadExtension(request)
    #expect(session.database.networkInstalls == ["excel"])
    #expect(session.database.loadedExtensions["excel"] == .loaded)
    #expect(session.database.loadedExtensions["delta"] != .loaded)
    #expect(!session.allowRemoteAtLaunch)
    let table = try await session.openPath(path)
    #expect(table.spec.fmt == .xlsx)
    let page = try await session.page(table.name, offset: 0, limit: 5)
    #expect(!page.rows.isEmpty)
    try await session.downloadExtension(request)
    #expect(session.database.networkInstalls == ["excel"], "An already available extension needs no second download")
}

@Test(.engineLifetime) func extensionConsentEngineDatabaseDefaultsToLoadOnly() throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    let session = try coldConsentSession(repository: server.baseURL)
    session.database.loadExtensions(["excel"])
    #expect(session.database.loadedExtensions["excel"] != .loaded)
    #expect(session.database.networkInstalls.isEmpty)
    #expect(server.requestLog.isEmpty)
}
