/// A selector may restore its previous app only while the user has not chosen another app.
@MainActor
final class SelectionFocusRestoration {
    private var activation: (() -> Void)?

    init(activation: @escaping () -> Void) {
        self.activation = activation
    }

    func restore() {
        let pendingActivation = activation
        activation = nil
        pendingActivation?()
    }

    func discard() {
        activation = nil
    }
}
