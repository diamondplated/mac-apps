import XCTest
import Foundation
@testable import PhotoServe

#if DEBUG
private actor SocketFixtureDelegate: ServeDelegate {
    func approvePairing(deviceName: String, fromHost: String) async -> Bool { false }
    func folderList() async -> [SharedFolderSummary] { [] }
    func photoList(folderID: String) async -> [PhonePhoto] { [] }
    func thumbnailJPEG(photoID: String) async -> Data? { nil }
    func previewJPEG(photoID: String) async -> Data? { nil }
    func apply(action: PhoneAction, photoID: String) async { }
    func search(folderID: String, query: String) async -> [String]? { nil }
}

/// Real sockets, exclusively on loopback, with no app UI, photos, or pairing.
@MainActor
final class LocalServerSocketTests: XCTestCase {
    func testPublicEntryPointStillRejectsLoopbackOverride() async {
        let server = LocalServer()
        let router = Router(pairing: PairingManager(), delegate: SocketFixtureDelegate())
        do {
            _ = try await server.start(router: router, address: "127.0.0.1")
            XCTFail("the internal fixture entry must not weaken public LAN selection")
        } catch LocalServer.LocalServerError.noLANInterface {
            // Expected: production accepts only its selected physical LAN address.
        } catch {
            XCTFail("unexpected rejection: \(error)")
        }
        await server.stop()
    }

    func testExplicitLoopbackBindingDeniesUnauthenticatedHTTPAndStopsAndRestarts() async throws {
        let server = LocalServer()
        let router = Router(pairing: PairingManager(), delegate: SocketFixtureDelegate())
        do {
            let firstPort = try await startWithDeadline(server: server, router: router)
            XCTAssertNotEqual(firstPort, 0, "ready must report the actual ephemeral port")
            try assertExplicitLoopbackListener(port: firstPort)
            let firstStatus = try await requestStatus(port: firstPort)
            XCTAssertEqual(firstStatus, 401, "an actual unauthenticated socket must reach the router's deny policy")

            await server.stop()
            try await assertStopped(port: firstPort)
            let stopped = await server.isRunning
            XCTAssertFalse(stopped)

            let secondPort = try await startWithDeadline(server: server, router: router)
            XCTAssertNotEqual(secondPort, 0)
            try assertExplicitLoopbackListener(port: secondPort)
            let secondStatus = try await requestStatus(port: secondPort)
            XCTAssertEqual(secondStatus, 401)
            await server.stop()
            try await assertStopped(port: secondPort)
        } catch {
            await server.stop()
            throw error
        }
    }

    private func startWithDeadline(server: LocalServer, router: Router) async throws -> UInt16 {
        try await withThrowingTaskGroup(of: UInt16.self) { group in
            group.addTask { try await server.startOnLoopbackForTesting(router: router) }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                // Cancel the listener too: cancelling only the task cannot resume
                // Network.framework's continuation when it stays in .waiting.
                await server.stop()
                throw NSError(domain: "SocketFixtureStartupTimeout", code: 1)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func listenerAddresses(port: UInt16) throws -> [String] {
        // Inspect only this test process and this port, not other user processes.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(ProcessInfo.processInfo.processIdentifier),
                             "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw NSError(domain: "SocketFixtureLsof", code: Int(process.terminationStatus))
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    private func assertExplicitLoopbackListener(port: UInt16) throws {
        XCTAssertEqual(try listenerAddresses(port: port), ["127.0.0.1:\(port)"],
                       "the kernel must show an explicit address, never a wildcard listener")
    }

    private func requestStatus(port: UInt16) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/api/folders")!)
        return try XCTUnwrap(response as? HTTPURLResponse).statusCode
    }

    private func assertStopped(port: UInt16) async throws {
        // NWListener.cancel is asynchronous; allow its socket close to complete.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(try listenerAddresses(port: port)).isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(try listenerAddresses(port: port).isEmpty, "stop left a live kernel listener")
        do {
            _ = try await requestStatus(port: port)
            XCTFail("a stopped listener accepted a new HTTP request")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost, "require refused connect, not a timeout")
        }
    }
}
#endif
