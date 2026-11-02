import Foundation
import QuickLookUI
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        try Task.checkCancellation()
        let url = request.fileURL
        // Quick Look invokes this block when it needs the bytes. Keep decoding
        // out of provider setup, and pass read failures back to Quick Look.
        // QLPreviewReply's contract uses its default loading size for .zero;
        // PNG intrinsic dimensions determine the final display size.
        return QLPreviewReply(dataOfContentType: .png, contentSize: .zero) { _ in
            try QuickLookPreviewContent.load(url: url).data
        }
    }
}
