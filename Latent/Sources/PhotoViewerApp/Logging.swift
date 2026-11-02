import os
import PipelineCore

/// Structured logging for Latent. Categories map to functional areas so
/// Console.app filtering works out of the box. Usage:
///   Log.scan.info("Found \(count) photos")
///   Log.pipeline.error("Stage failed: \(error)")
enum Log {
    private static let subsystem = "com.latent.photo-viewer"

    /// Folder scanning and file discovery.
    static let scan = Logger(subsystem: subsystem, category: "scan")

    /// Enhancement pipeline execution.
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")

    /// CLIP search indexing and queries.
    static let search = Logger(subsystem: subsystem, category: "search")

    /// Image I/O (reading, writing, thumbnails).
    static let io = Logger(subsystem: subsystem, category: "io")

    /// Cache operations (pipeline cache, thumbnail cache, prefetch).
    static let cache = Logger(subsystem: subsystem, category: "cache")

    /// Explicitly opted-in, fixed-field pipeline cache acceptance diagnostics.
    static let pipelineCacheTrace = Logger(subsystem: subsystem, category: "pipeline-cache-trace")

    /// GPS extraction and map view.
    static let geo = Logger(subsystem: subsystem, category: "geo")
}

/// Used only when LATENT_PIPELINE_CACHE_TRACE=1 in the app process environment.
/// Never log source identity, parameters, display names, or pixel/model data.
struct PipelineCacheTraceObserver: PipelineObserver {
    func stageStarted(stageID: StageID, displayName: String) async {}
    func stageProgress(stageID: StageID, fraction: Double) async {}

    func stageCompleted(stageID: StageID, cacheHit: Bool) async {
        // StageID is a String: whitelist the app's fixed IDs before making it
        // public in OSLog, even if a future caller supplies another stage.
        switch stageID {
        case "artifact-removal-fbcnn", "denoise-nafnet", "upscale", "sharpen-unsharp-mask":
            let hit = cacheHit ? "true" : "false"
            Log.pipelineCacheTrace.info("stageID=\(stageID, privacy: .public) status=completed cacheHit=\(hit, privacy: .public)")
        default:
            return
        }
    }
}
