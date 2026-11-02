import Observation
import SwiftUI

/// Keeps AppKit's termination reply behind the engine's asynchronous drain.
/// Closing is permanent: duplicate quit requests cannot admit more work or reply twice.
@MainActor
@Observable
public final class TerminationCoordinator {
    public private(set) var isClosing = false
    @ObservationIgnored private var drainTask: Task<Void, Never>?

    public init() {}

    public func request(
        stopAdmission: () -> Void,
        drain: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor () -> Void
    ) {
        guard !isClosing else { return }
        isClosing = true
        stopAdmission()
        drainTask = Task {
            await drain()
            reply()
            self.drainTask = nil
        }
    }
}

/// Disables the existing window content for the entire deferred-quit interval.
public struct TerminationContent<Content: View>: View {
    @Bindable private var termination: TerminationCoordinator
    private let content: Content

    public init(termination: TerminationCoordinator, @ViewBuilder content: () -> Content) {
        self.termination = termination
        self.content = content()
    }

    public var body: some View { content.disabled(termination.isClosing) }
}
