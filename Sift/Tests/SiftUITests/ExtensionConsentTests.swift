import DuckDBKit
import Foundation
import Testing
@testable import SiftEngine
@testable import SiftUI

@MainActor
private func requireDownload(_ name: String, path: String) -> SessionError {
    SessionError("Download needed", extensionDownload:
        ExtensionDownloadRequest(extensionName: name, sourcePath: path))
}

@MainActor
@Test func extensionConsentCancelNeverDownloadsOrOpens() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    let path = try makeCSV(in: tempDir(), rows: 3)
    var downloads = 0
    state.beforeOpenForTest = { path in throw requireDownload("excel", path: path) }
    state.downloadExtensionForTest = { _ in downloads += 1 }
    await state.open(path: path, sheet: "Sheet 2", nullPadding: true, skipPreamble: false)
    let prompt = try #require(state.extensionDownloadPrompt)
    #expect(prompt.message.contains("Excel"))
    #expect(prompt.message.contains("extensions.duckdb.org"))
    #expect(prompt.message.contains("not uploaded"))
    #expect(prompt.opens[0].sheet == "Sheet 2")
    #expect(prompt.opens[0].nullPadding)
    #expect(!prompt.opens[0].skipPreamble)
    #expect(downloads == 0)
    #expect(state.tables.isEmpty)
    state.cancelExtensionDownload(prompt.id)
    #expect(state.extensionDownloadPrompt == nil)
    #expect(downloads == 0)
    #expect(state.tables.isEmpty)
}

@MainActor
@Test func extensionConsentApprovesOnlyThePresentedPromptAndRetriesGroupedOpens() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    let directory = tempDir()
    let first = try makeCSV(in: directory, name: "first.csv", rows: 3)
    let second = try makeCSV(in: directory, name: "second.csv", rows: 3)
    var installed = false
    var downloads = 0
    state.beforeOpenForTest = { path in
        if !installed { throw requireDownload("excel", path: path) }
    }
    state.downloadExtensionForTest = { request in
        #expect(request.extensionName == "excel")
        downloads += 1
        installed = true
    }
    await state.open(paths: [first, second])
    let prompt = try #require(state.extensionDownloadPrompt)
    #expect(prompt.opens.count == 2)
    #expect(downloads == 0)
    await state.approveExtensionDownload(UUID())
    #expect(downloads == 0)
    #expect(state.tables.isEmpty)
    await state.approveExtensionDownload(prompt.id)
    #expect(downloads == 1)
    #expect(state.tables.count == 2)
    #expect(state.extensionDownloadPrompt == nil)
    await state.open(path: first)
    #expect(downloads == 1)
    #expect(state.extensionDownloadPrompt == nil)
}

@MainActor
@Test func extensionConsentDoesNotAuthorizeADifferentExtension() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    let directory = tempDir()
    let first = try makeCSV(in: directory, name: "excel.csv", rows: 3)
    let second = try makeCSV(in: directory, name: "delta.csv", rows: 3)
    var installed = Set<String>()
    var downloads: [String] = []
    state.beforeOpenForTest = { path in
        let name = path == first ? "excel" : "delta"
        if !installed.contains(name) { throw requireDownload(name, path: path) }
    }
    state.downloadExtensionForTest = { request in
        downloads.append(request.extensionName)
        installed.insert(request.extensionName)
    }
    await state.open(paths: [first, second])
    let firstPrompt = try #require(state.extensionDownloadPrompt)
    await state.approveExtensionDownload(firstPrompt.id)
    #expect(downloads == ["excel"])
    #expect(state.tables.count == 1)
    let next = try #require(state.extensionDownloadPrompt)
    #expect(next.extensionName == "delta")
    #expect(next.message.contains("Delta"))
    state.cancelExtensionDownload(next.id)
    #expect(downloads == ["excel"])
    #expect(state.tables.count == 1)
}

@MainActor
@Test func extensionConsentDownloadFailureReportsErrorWithoutOpening() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    let path = try makeCSV(in: tempDir(), rows: 3)
    state.beforeOpenForTest = { path in throw requireDownload("excel", path: path) }
    state.downloadExtensionForTest = { _ in throw SessionError("Download failed.") }
    await state.open(path: path)
    let prompt = try #require(state.extensionDownloadPrompt)
    await state.approveExtensionDownload(prompt.id)
    #expect(state.banner == "Download failed.")
    #expect(state.tables.isEmpty)
    #expect(state.extensionDownloadPrompt == nil)
    #expect(!state.downloadingExtension)
}


@Test func extensionConsentMissingOptionalReadersAreNotLaunchWarnings() {
    let warnings = extensionsNeedingWarning([
        "excel": .unavailable("not installed"), "delta": .unavailable("not installed"),
        "httpfs": .unavailable("network failed"), "unexpected": .rejectedName,
    ])
    #expect(warnings["excel"] == nil)
    #expect(warnings["delta"] == nil)
    #expect(warnings["httpfs"] == .unavailable("network failed"))
    #expect(warnings["unexpected"] == .rejectedName)
}
