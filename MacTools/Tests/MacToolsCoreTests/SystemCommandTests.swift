import Foundation
import Testing
@testable import MacToolsCore

struct SystemCommandTests {
    @Test func separatesOutputAndErrors() async throws {
        let result = try await SystemCommand.run("/usr/bin/printf", arguments: ["%s", "hello; $(unused)"])
        #expect(result.output == "hello; $(unused)")
        #expect(result.status == 0)
    }
    @Test func capsOutputAndRetainsTail() async throws {
        let first = try await SystemCommand.run("/usr/bin/printf", arguments: ["123456789"], maximumOutputBytes: 4)
        let last = try await SystemCommand.run("/usr/bin/printf", arguments: ["123456789"], maximumOutputBytes: 4, retainOutputTail: true)
        #expect(first.output == "1234" && first.truncated)
        #expect(last.output == "6789" && last.truncated)
    }
    @Test func timeoutTerminatesChild() async {
        do { _ = try await SystemCommand.run("/bin/sleep", arguments: ["5"], timeout: 0.1); Issue.record("Expected timeout") }
        catch { #expect(error is SystemCommandError) }
    }
    @Test func cancellationTerminatesChild() async {
        let work = Task { try await SystemCommand.run("/bin/sleep", arguments: ["5"]) }
        try? await Task.sleep(for: .milliseconds(80))
        work.cancel()
        do { _ = try await work.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }
}
