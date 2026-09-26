import Foundation

/// Keeps the Dock-to-preview crossing forgiving without treating empty space as hover.
struct HoverDismissalState {
    private var departedAt: TimeInterval?
    private let gracePeriod: TimeInterval = 0.6

    mutating func shouldDismiss(
        pointer: CGPoint,
        dockFrame: CGRect?,
        previewFrame: CGRect?,
        now: TimeInterval
    ) -> Bool {
        if dockFrame?.contains(pointer) == true || previewFrame?.contains(pointer) == true {
            reset()
            return false
        }

        guard let departedAt else {
            self.departedAt = now
            return false
        }

        // Repeated movement outside must not push the deadline back.
        return now - departedAt >= gracePeriod
    }

    mutating func reset() {
        departedAt = nil
    }
}
