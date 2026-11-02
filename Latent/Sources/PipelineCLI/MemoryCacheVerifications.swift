import Foundation
import PipelineCore
import PhotoML
import PhotoIO
import EnhancementStages

func oversizedCachePreservesUpstream() async throws {
    let cache = IntermediateCache(maxBytes: 5000)
    let key = { CacheKey(inputHash: ContentHash(value: $0), stagePath: []) }
    let small = makeInput()
    await cache.put(small, for: key(1))
    await cache.put(small, for: key(2))
    await cache.put(makeInput(w: 32, h: 32), for: key(3))
    await cache.put(makeInput(w: 32, h: 32), for: key(1))
    let one = await cache.get(key(1))
    let two = await cache.get(key(2))
    let count = await cache.count
    try require(one?.pixels == small.pixels && two != nil && count == 2,
                "oversized insertion/replacement evicted upstream cache entries")
}

func enhancementMemoryCeilings() async throws {
    for dimensions in [(20_000, 20_000, 1), (Int.max, 2, 4)] {
        do {
            _ = try ImageMemoryPolicy.validate(width: dimensions.0, height: dimensions.1, scale: dimensions.2)
            throw VerifyError(message: "oversized dimensions accepted")
        } catch is ImageMemoryPolicy.LimitError { }
    }
    let url = tempURL("png")
    defer { try? FileManager.default.removeItem(at: url) }
    let input = makeInput()
    try ImageWriter().write(buffer: input, metadata: nil, to: url, options: .init(format: .png))
    do {
        _ = try ImageReader(maxWorkingMemoryBytes: 1).read(url: url)
        throw VerifyError(message: "reader ignored memory ceiling")
    } catch is ImageMemoryPolicy.LimitError { }
    do {
        _ = try await Upscale(maxWorkingMemoryBytes: 1).process(input: input, params: .init(), progress: .noop)
        throw VerifyError(message: "upscale ignored memory ceiling")
    } catch is ImageMemoryPolicy.LimitError { }
}

func modelAvailabilityInvalidatesIntermediates() async throws {
    try await checkModelAvailabilityOnMainActor()
}

@MainActor
private func checkModelAvailabilityOnMainActor() async throws {
    let store = EnhancementModelCache(maxBytes: 5000)
    let old = store.cache
    let key = CacheKey(inputHash: ContentHash(value: 1), stagePath: [])
    await old.put(makeInput(), for: key)
    store.refresh(models: [:])
    try require(store.cache === old, "unchanged availability discarded useful cache")
    let models: [ModelID: URL] = [.upscaleRealESRGANx2: URL(fileURLWithPath: "/synthetic/model.mlpackage")]
    store.refresh(models: models)
    let new = store.cache
    await old.put(makeInput(), for: key) // late completion must remain isolated
    let cached = await new.get(key)
    try require(new !== old && cached == nil, "new installation reused fallback pixels")
    store.refresh(models: models)
    try require(store.cache === new, "stable installed model discarded cache")
    store.refresh(models: [:])
    try require(store.cache !== new, "model removal retained stale cache")
}


func newModelRetriesLoad() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = directory.appendingPathComponent("new.mlmodelc")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = ModelManager(resolve: { _ in
        FileManager.default.fileExists(atPath: model.path) ? model : nil
    })
    let absent = try await manager.model(for: .upscaleRealESRGANx2, spec: .realESRGANx2)
    try require(absent == nil, "missing model did not fall back")
    // Invalid compiled fixture proves the second call actually attempts a load,
    // without real weights, runtime downloads or touching installed model stores.
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    do {
        _ = try await manager.model(for: .upscaleRealESRGANx2, spec: .realESRGANx2)
        throw VerifyError(message: "new model was hidden by a cached miss")
    } catch let error as CoreMLModelError {
        guard case .modelLoadFailed = error else { throw error }
    }
}
