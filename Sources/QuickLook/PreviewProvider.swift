import Cocoa
import QuickLookUI
import UniformTypeIdentifiers

/// Quick Look preview (Space bar in Finder) for Markdown files.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let reply = QLPreviewReply(dataOfContentType: .html,
                                   contentSize: CGSize(width: 900, height: 800)) { reply in
            let markdown = try MarkdownRenderer.readText(at: url)
            let html = MarkdownRenderer.htmlDocument(markdown: markdown, fileURL: url)
            reply.stringEncoding = .utf8
            reply.title = url.lastPathComponent
            return Data(html.utf8)
        }
        return reply
    }
}
