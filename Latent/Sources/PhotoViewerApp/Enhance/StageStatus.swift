import SwiftUI
import AppKit
import EnhancementStages
import PhotoML

/// What a stage will actually do on the next pipeline run, based on whether
/// its CoreML model is installed. Drives the one-line status under each
/// inspector section header.
enum StageStatus: Equatable {
    /// Classical algorithm; no model needed. Always real.
    case classical
    /// ML model installed — full inference path active.
    case mlActive
    /// ML model missing, but the stage degrades gracefully to a useful
    /// non-ML fallback (Upscale → Lanczos resize).
    case mlMissingWithFallback(fallbackName: String)
    /// ML model missing and there's no fallback — the switch would do
    /// nothing, so the inspector disables it.
    case mlMissingPlacebo

    /// Short status shown under the section header. Nil when there is
    /// nothing worth saying (a classical stage simply works).
    var summary: String? {
        switch self {
        case .classical: nil
        case .mlActive: "Model installed"
        case .mlMissingWithFallback(let name): "Model not installed · using \(name)"
        case .mlMissingPlacebo: "Model not installed"
        }
    }

    /// True when a missing model is the reason for the status, so the
    /// inspector offers the help button that explains how to install it.
    var offersInstallHelp: Bool {
        switch self {
        case .classical, .mlActive: false
        case .mlMissingWithFallback, .mlMissingPlacebo: true
        }
    }

    /// True when the stage's switch should actually be interactive. False
    /// for placebo stages (the switch would do literally nothing).
    var isOperational: Bool {
        switch self {
        case .classical, .mlActive, .mlMissingWithFallback: true
        case .mlMissingPlacebo: false
        }
    }
}

/// Resolve the live status of each pipeline stage based on which `.mlpackage`
/// files are currently in the model registry. Re-runs cheap-ish (one fs stat
/// per stage) so it's safe to call from a SwiftUI view body.
enum StageStatusResolver {
    static func artifactRemoval() -> StageStatus {
        ModelRegistry.url(for: .artifactRemovalFBCNN) != nil
            ? .mlActive
            : .mlMissingPlacebo
    }

    static func denoise() -> StageStatus {
        ModelRegistry.url(for: .denoiseNAFNet) != nil
            ? .mlActive
            : .mlMissingPlacebo
    }

    /// Upscale degrades to Lanczos resize when no model is present — real
    /// resampling, just not ML super-resolution.
    static func upscale() -> StageStatus {
        ModelRegistry.url(for: Upscale.modelID) != nil
            ? .mlActive
            : .mlMissingWithFallback(fallbackName: "Lanczos")
    }

    /// Always classical — Sharpen uses Core Image's CIUnsharpMask, no ML.
    static func sharpen() -> StageStatus { .classical }
}

/// Where the model-install instructions live. The help buttons open this in
/// the user's browser; Latent itself makes no request.
enum ModelInstallHelp {
    static let url = URL(string: "https://github.com/diamondplated/mac-apps/blob/main/Latent/README.md#installing-models")!

    @MainActor
    static func open() {
        NSWorkspace.shared.open(url)
    }
}
