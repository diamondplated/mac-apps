import Foundation
import QuickLookUI
import SiftPreview
import UniformTypeIdentifiers

// The whole extension. Everything with a decision in it is in SiftPreview, where a test can reach
// it; this class only hands the file to the engine and the page back to Quick Look.
@objc(SiftPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let model = await PreviewEngine.preview(url: url)
        let html = renderPreviewHTML(model)
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 960, height: 640)) { reply in
            reply.stringEncoding = .utf8
            return Data(html.utf8)
        }
        return reply
    }
}
