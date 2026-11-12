import Foundation

/// Model identifiers known to the registry. Adding a new model = adding a case.
public enum ModelID: String, Sendable, CaseIterable {
    case upscaleRealESRGANx2 = "upscale-realesrgan-x2"
    case denoiseNAFNet = "denoise-nafnet"
    case artifactRemovalFBCNN = "artifact-removal-fbcnn"
    case openCLIPImageEncoder = "openclip-vitb32-image"
    case openCLIPTextEncoder = "openclip-vitb32-text"
}

/// Where the registry looks for models. In dev / open-source, models live in
/// the repo's `Resources/Models/` (gitignored). Released app: in
/// `~/Library/Application Support/photo-viewer/Models/`, installed by user-run setup scripts.
public enum ModelRegistry {

    /// Resolve a model file URL. Returns nil if no .mlpackage exists yet —
    /// callers should treat that as "model not available" and fall back
    /// gracefully (e.g., identity passthrough).
    public static func url(for id: ModelID) -> URL? {
        let fileName = "\(id.rawValue).mlpackage"

        // Search order: developer-controlled paths first, then the user-data
        // location where user-installed files end up.
        for dir in searchDirectories() {
            let candidate = dir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            // Also check for compiled .mlmodelc — compileModel(at:) outputs this.
            let compiled = dir.appendingPathComponent("\(id.rawValue).mlmodelc")
            if FileManager.default.fileExists(atPath: compiled.path) {
                return compiled
            }
        }
        return nil
    }

    /// Directory where user-installed models are stored.
    public static func userModelsDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("photo-viewer/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Search directories in priority order.
    private static func searchDirectories() -> [URL] {
        var dirs: [URL] = []

        // 1. Override via env var (CI / scripts).
        if let envPath = ProcessInfo.processInfo.environment["PV_MODELS_DIR"] {
            // An explicit override is exclusive, including when empty.
            // This keeps tests and custom model stores isolated from user data.
            return [URL(fileURLWithPath: envPath, isDirectory: true)]
        }

        // 2. Repo Resources/Models (when running from a checkout).
        // SourceFile-relative path: Sources/PhotoML/ModelRegistry.swift → ../../Resources/Models
        // Skipped inside an app bundle: #filePath is wherever the release was
        // built, which may not exist on this Mac, and anyone able to create
        // it could hand the app a model ahead of its own bundle.
        if !Bundle.main.bundlePath.hasSuffix(".app") {
            let thisFile = URL(fileURLWithPath: #filePath)
            let repoModels = thisFile
                .deletingLastPathComponent()  // Sources/PhotoML
                .deletingLastPathComponent()  // Sources
                .deletingLastPathComponent()  // repo root
                .appendingPathComponent("Resources/Models", isDirectory: true)
            dirs.append(repoModels)
        }

        // 3. App bundle Resources (production builds).
        if let bundleResources = Bundle.main.resourceURL {
            dirs.append(bundleResources.appendingPathComponent("Models", isDirectory: true))
        }

        // 4. User Application Support (user-installed location).
        if let userDir = try? userModelsDirectory() {
            dirs.append(userDir)
        }

        return dirs
    }
}
