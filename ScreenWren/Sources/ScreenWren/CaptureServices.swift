import AppKit

// Keep acquisition and delivery replaceable so asynchronous ordering can be
// verified without recording the desktop or touching the general clipboard.
@MainActor
struct CaptureServices {
    var hasScreenAccess: @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }
    var frontWindow: @MainActor () async throws -> WindowCandidate? = { try await WindowCandidate.eligible().first }
    var screenshot: @MainActor (SelectionTarget) async throws -> CGImage = { try await acquireScreenshot(for: $0) }
    var text: @MainActor (CGImage) async throws -> String = { try await recognizedText(in: $0) }
    var overlap: @MainActor (CGImage, CGImage, Int) async throws -> Int = { previous, next, index in
        let pair = SendableImageBatch(images: [previous, next])
        return try await Task.detached(priority: .userInitiated) {
            try validatedScrollingOverlap(previous: pair.images[0], next: pair.images[1], newFrameIndex: index)
        }.value
    }
    var stitch: @MainActor ([CGImage]) async throws -> CGImage = { images in
        let batch = SendableImageBatch(images: images)
        return try await Task.detached(priority: .userInitiated) {
            SendableImage(image: try stitchCGImagesVertically(batch.images))
        }.value.image
    }
    var copyImage: @MainActor (CGImage, NSPasteboard) throws -> Void = { image, pasteboard in
        let value = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([value]) else { throw CaptureError.clipboardWriteFailed }
    }
}
