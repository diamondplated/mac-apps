import Foundation
import PhotoIO
import PipelineCore
import EnhancementStages

func lifecycleTrashAndArchiveSafety() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("latent-lifecycle-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("photo")
    let destination = root.appendingPathComponent("fixture-trash")
    let bytes = Data("photo bytes".utf8)
    try bytes.write(to: source)
    let trash = RecoverableTrash { url in
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
    let receipt = try trash.trash(source)
    try require(receipt.trashURL == destination && !fm.fileExists(atPath: source.path), "trash must return a recoverable receipt")
    try bytes.write(to: source)
    var refused = false
    do { try trash.restore(originalURL: source, trashURL: destination) } catch { refused = true }
    try require(refused, "undo must refuse an occupied original path")
    try fm.removeItem(at: source)
    try trash.restore(originalURL: source, trashURL: destination)
    let restoredBytes = try Data(contentsOf: source)
    try require(restoredBytes == bytes, "undo must preserve photo bytes")

    let active = try ArchiveTemporaryStorage.createDirectory(root: root)
    defer { try? ArchiveTemporaryStorage.remove(active) }
    let stale = root.appendingPathComponent("pv-archive-\(UUID().uuidString)")
    try fm.createDirectory(at: stale, withIntermediateDirectories: false)
    try Data().write(to: stale.appendingPathComponent(".latent-extraction-lease-v1"))
    try ArchiveTemporaryStorage.sweepInactiveDirectories(root: root)
    try require(fm.fileExists(atPath: active.path), "active archive lease must survive sweep")
    try require(!fm.fileExists(atPath: stale.path), "stale marked extraction must be removed")
}

func missingModelFallbacks() async throws {
    guard let path = ProcessInfo.processInfo.environment["PV_MODELS_DIR"],
          try FileManager.default.contentsOfDirectory(atPath: path).isEmpty else {
        print("  skip: missing-model verification needs an empty private PV_MODELS_DIR")
        return
    }
    let input = ImageBuffer(width: 4, height: 3, format: .working, pixels: Data(count: 96))
    let artifact = try await ArtifactRemoval().process(input: input, params: .init(), progress: .noop)
    let denoise = try await Denoise().process(input: input, params: .init(), progress: .noop)
    try require(artifact.contentHash == input.contentHash && denoise.contentHash == input.contentHash,
                "missing restoration models must pass input through unchanged")
    let upscale = try await Upscale().process(input: input, params: .init(scale: 2), progress: .noop)
    try require(upscale.width == 8 && upscale.height == 6, "missing upscale model must produce 2x Lanczos fallback")
}
