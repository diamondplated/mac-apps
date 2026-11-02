import Foundation
import PipelineCore

/// A new model installation changes pixels without changing the recipe. Replace
/// the cache on that transition; an older in-flight run retains only its old cache.
@MainActor
public final class EnhancementModelCache {
    private var models: [ModelID: URL] = [:]
    public private(set) var cache: IntermediateCache
    private let maxBytes: Int

    public init(maxBytes: Int) {
        self.maxBytes = maxBytes
        cache = IntermediateCache(maxBytes: maxBytes)
    }

    public func refresh(models current: [ModelID: URL]) {
        guard current != models else { return }
        models = current
        cache = IntermediateCache(maxBytes: maxBytes)
    }

    public func refresh() {
        refresh(models: Dictionary(uniqueKeysWithValues: ModelID.allCases.compactMap { id in
            ModelRegistry.url(for: id).map { (id, $0) }
        }))
    }
}
