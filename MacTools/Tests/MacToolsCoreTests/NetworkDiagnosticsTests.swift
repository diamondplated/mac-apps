import Foundation
import XCTest
@testable import MacToolsCore

final class NetworkDiagnosticsTests: XCTestCase {
    func testWebsiteValidation() throws {
        XCTAssertEqual(try NetworkDiagnostics.validatedURL("https://example.com/path?q=test").host, "example.com")
        XCTAssertEqual(try NetworkDiagnostics.validatedURL("  http://localhost:8080  ").port, 8080)
        XCTAssertNoThrow(try NetworkDiagnostics.validatedURL("https://[::1]/"))
        for input in ["example.com", "file:///etc/hosts", "ftp://example.com", "https://", "https://user:secret@example.com", "https://user@example.com", "https://example.com\n", "https://example.com/\tfoo", "https://example.com/%0aevil", "https://example.com:0", "https://example.com:65536"] {
            XCTAssertThrowsError(try NetworkDiagnostics.validatedURL(input), input)
        }
    }

    func testAlreadyCancelledRunStopsBeforeCollectingEvidence() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await NetworkDiagnostics.run(url: URL(string: "https://example.com")!, includeReference: false) { _ in
                XCTFail("A cancelled run must not start a stage")
            }
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testHTTPErrorMeansServerReached() {
        let response = NetworkDiagnostics.responseStage(status: 503, reference: false, redirected: false)
        XCTAssertEqual(response.state, .attention)
        XCTAssertTrue(response.detail.contains("server is reachable"))
        XCTAssertEqual(response.id, "website")
    }

    func testReferenceRedirectOnlyHintsAtCaptivePortal() {
        let response = NetworkDiagnostics.responseStage(status: 302, reference: true, redirected: true)
        XCTAssertEqual(response.state, .attention)
        XCTAssertTrue(response.detail.contains("does not prove a captive portal"))
        XCTAssertEqual(response.id, "internet")
        XCTAssertEqual(NetworkDiagnostics.responseStage(status: 302, reference: false, redirected: true).state, .passed)
    }

    func testTransportFailuresHaveDistinctEvidence() {
        XCTAssertTrue(NetworkDiagnostics.transportStage(code: .cannotFindHost, reference: false).detail.contains("resolve"))
        XCTAssertTrue(NetworkDiagnostics.transportStage(code: .serverCertificateUntrusted, reference: false).detail.contains("TLS"))
        XCTAssertTrue(NetworkDiagnostics.transportStage(code: .timedOut, reference: false).detail.contains("timeout alone"))
        XCTAssertTrue(NetworkDiagnostics.transportStage(code: .networkConnectionLost, reference: true).detail.contains("does not identify"))
        XCTAssertEqual(NetworkDiagnostics.responseStage(status: 200, reference: true, redirected: false).state, .passed)
    }
}
