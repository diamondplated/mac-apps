import Foundation
import CoreML
import Darwin
import PipelineCore
import PhotoML
import EnhancementStages

/// Runs in a fresh verifier process so installing a fixture cannot race any
/// other test or observe the user's actual model directory.
func liveModelInstallSubprocess() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--verify-model-install"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    try require(process.terminationStatus == 0 && text.contains("PASS valid model install replaces cached fallback"),
                "isolated live-model proof failed: \(text)")
}

@MainActor
func verifyLiveModelInstall() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("latent-live-model-\(UUID().uuidString)")
    let models = root.appendingPathComponent("models")
    try fm.createDirectory(at: models, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    // This branch is selected before any pipeline/model tasks are created.
    // The entire child process exits afterward; no parent environment changes.
    setenv("PV_MODELS_DIR", models.path, 1)
    let store = EnhancementModelCache(maxBytes: 1_000_000)
    store.refresh()
    let steps = [PipelineStep(stage: AnyStage(Upscale(), params: Upscale.Params()))]
    var components = [Float16]()
    for index in 0..<(16 * 16 * 4) {
        let value: Float = index % 4 == 3 ? 1 : Float(index % 17) / 20 + 0.1
        components.append(Float16(value))
    }
    let pixels = components.withUnsafeBytes { Data($0) }
    let input = ImageBuffer(width: 16, height: 16, format: .working, pixels: pixels)
    let fallbackPipeline = Pipeline(steps: steps, cache: store.cache)
    let fallback = try await fallbackPipeline.run(input: input)
    let warmObserver = RecordingObserver()
    let warmFallback = try await fallbackPipeline.run(input: input, observer: warmObserver)
    let warmEvents = await warmObserver.snapshot()
    try require(warmFallback.pixels == fallback.pixels && warmEvents.contains(.complete("upscale", cacheHit: true)),
                "pre-install fallback was not cached")

    let source = root.appendingPathComponent("marker.mlmodel")
    try TinyMarkerModel.bytes.write(to: source)
    let compiled = try await MLModel.compileModel(at: source)
    defer { try? fm.removeItem(at: compiled) }
    let staged = root.appendingPathComponent("staged.mlmodelc")
    try fm.copyItem(at: compiled, to: staged)
    try fm.moveItem(at: staged, to: models.appendingPathComponent("upscale-realesrgan-x2.mlmodelc"))

    // Same process, input, recipe and shared ModelManager as the missing-model
    // run. Match the app's runPipeline refresh; do not reset the manager.
    store.refresh()
    let installedPipeline = Pipeline(steps: steps, cache: store.cache)
    let coldObserver = RecordingObserver()
    let installed = try await installedPipeline.run(input: input, observer: coldObserver)
    let coldEvents = await coldObserver.snapshot()
    try require(coldEvents.contains(.complete("upscale", cacheHit: false)), "installed model reused fallback cache")
    try require(installed.width == 32 && installed.height == 32, "model output was not 2x")
    try require(installed.pixels != fallback.pixels, "new model output matched cached Lanczos fallback")
    let values = installed.pixels.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
    // The marker emits sRGB 0.25; the production converter restores linear RGB.
    let expected = Float(pow((0.25 + 0.055) / 1.055, 2.4))
    for (index, value) in values.enumerated() {
        let target: Float = index % 4 == 3 ? 1 : expected
        try require(abs(Float(value) - target) < 0.002, "valid model marker did not reach pipeline output")
    }
    let modelWarmObserver = RecordingObserver()
    let modelWarm = try await installedPipeline.run(input: input, observer: modelWarmObserver)
    let modelWarmEvents = await modelWarmObserver.snapshot()
    try require(modelWarm.pixels == installed.pixels && modelWarmEvents.contains(.complete("upscale", cacheHit: true)),
                "installed model output did not cache")
    print("PASS valid model install replaces cached fallback")
}

/// A generated 2-layer fixture, not pretrained weights. Writes only the small
/// protobuf subset documented by Apple's coremltools 9.0 schema:
/// https://github.com/apple/coremltools/tree/9.0/mlmodel/format
/// Model(version=4), Float32 NCHW arrays, exact shape mapping, LINEAR(0,.25)
/// followed by nearest-neighbor upsample(2,2). CoreML compiles/validates it.
private enum TinyMarkerModel {
    static var bytes: Data {
        let description = message(1, feature("input", [1, 3, 16, 16]))
            + message(10, feature("output", [1, 3, 32, 32]))
        let linear = message(5, float(1, 0) + float(2, 0.25))
        let marker = layer("marker", "input", "marked", 130, linear)
        let upsample = layer("double", "marked", "output", 210, message(1, Data([2, 2])))
        let network = message(1, marker) + message(1, upsample) + integer(5, 1)
        return integer(1, 4) + message(2, description) + message(500, network)
    }
    private static func feature(_ name: String, _ shape: [UInt64]) -> Data {
        let array = message(1, shape.reduce(Data()) { $0 + varint($1) }) + integer(2, 65568)
        return message(1, Data(name.utf8)) + message(3, message(5, array))
    }
    private static func layer(_ name: String, _ input: String, _ output: String, _ tag: UInt64, _ params: Data) -> Data {
        message(1, Data(name.utf8)) + message(2, Data(input.utf8))
            + message(3, Data(output.utf8)) + message(tag, params)
    }
    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes = Data()
        while value >= 128 { bytes.append(UInt8(value & 127) | 128); value >>= 7 }
        bytes.append(UInt8(value))
        return bytes
    }
    private static func integer(_ tag: UInt64, _ value: UInt64) -> Data { varint(tag << 3) + varint(value) }
    private static func message(_ tag: UInt64, _ value: Data) -> Data {
        varint(tag << 3 | 2) + varint(UInt64(value.count)) + value
    }
    private static func float(_ tag: UInt64, _ value: Float) -> Data {
        var bits = value.bitPattern.littleEndian
        return varint(tag << 3 | 5) + withUnsafeBytes(of: &bits) { Data($0) }
    }
}
