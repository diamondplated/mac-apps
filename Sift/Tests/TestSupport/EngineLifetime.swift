import Testing
import SiftEngine

public struct EngineLifetime: TestTrait, TestScoping {
    public func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await SessionLifetime.withScope(function)
    }
}

extension Trait where Self == EngineLifetime {
    public static var engineLifetime: Self { Self() }
}
