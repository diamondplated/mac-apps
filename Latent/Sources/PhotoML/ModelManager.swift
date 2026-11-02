import Foundation
import CoreML

/// Process-wide cache of loaded CoreML models. Loading an `.mlpackage` is
/// expensive (~hundreds of ms, plus first-call ANE warmup). The pipeline can
/// run hundreds of times in a session — share loaded models across all runs.
public actor ModelManager {
    public static let shared = ModelManager()

    private let resolve: @Sendable (ModelID) -> URL?

    public init(resolve: @escaping @Sendable (ModelID) -> URL? = { ModelRegistry.url(for: $0) }) {
        self.resolve = resolve
    }

    private var cache: [ModelID: CoreMLImageModel] = [:]

    /// Returns a loaded model for `id`, or nil if the model file isn't on
    /// disk yet. Subsequent calls hit the cache.
    public func model(for id: ModelID, spec: TensorSpec, computeUnits: MLComputeUnits = .all) async throws -> CoreMLImageModel? {
        if let existing = cache[id] { return existing }

        guard let url = resolve(id) else {
            return nil
        }

        let model = try await CoreMLImageModel(id: id, spec: spec, computeUnits: computeUnits, resolvedURL: url)
        cache[id] = model
        return model
    }

    /// Forget any cached model state. Useful after the user
    /// downloads new models so subsequent calls discover them.
    public func reset() {
        cache.removeAll()
    }
}
