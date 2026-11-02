import Foundation

/// Structured ownership for callers such as a test runner that create multiple sessions.
/// A scope closes every still-live session before returning, including on an error. Weak entries
/// preserve normal ARC/deinit behavior; detached engine work itself retains its session.
public enum SessionLifetime {
    @TaskLocal static var current: Scope?

    public static nonisolated(nonsending) func withScope<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        let scope = Scope()
        do {
            let value = try await $current.withValue(scope, operation: { try await operation() })
            await scope.close()
            return value
        } catch {
            await scope.close()
            throw error
        }
    }

    final class Scope: @unchecked Sendable {
        private final class Entry { weak var session: Session?; init(_ session: Session) { self.session = session } }
        private let lock = NSLock()
        private var sessions: [Entry] = []
        private var closing = false
        private let initializers = SessionWork()
        func beginInitialization() throws {
            try lock.withLock {
                guard !closing else { throw SessionError("This session scope is closing.") }
                initializers.begin()
            }
        }
        func register(_ session: Session) { lock.withLock { sessions.append(Entry(session)) } }
        func finishInitialization() { initializers.finish() }
        func close() async {
            lock.withLock { closing = true }
            await initializers.drain()
            let live = lock.withLock { sessions.compactMap(\.session) }
            for session in live { await session.shutdown() }
        }
    }
}

/// Counts work before its detached task is launched, and completes it only after its final actor
/// callback. Awaiting the count never occupies a cooperative worker or the main thread.
final class SessionWork: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var interruptions: [StageJob] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func begin(interrupt: StageJob? = nil) {
        lock.withLock {
            count += 1
            if let interrupt { interruptions.append(interrupt) }
        }
    }
    func cancel() {
        let jobs = lock.withLock { interruptions }
        for job in jobs { job.requestCancel() }
    }
    func finish() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            count -= 1
            guard count == 0 else { return [] }
            interruptions.removeAll()
            defer { waiters.removeAll() }
            return waiters
        }
        for continuation in ready { continuation.resume() }
    }
    func drain() async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                if count == 0 { return true }
                waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }
}
