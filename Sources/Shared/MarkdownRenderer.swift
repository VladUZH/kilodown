import Foundation
import JavaScriptCore

/// Turns Markdown text into a complete, self-contained HTML page.
/// Shared by the viewer app and the Quick Look extension.
enum MarkdownRenderer {
    private static let lock = NSLock()
    private static var cachedContext: JSContext?
    private static let maxInlineImageBytes = 40 * 1024 * 1024

    // MARK: - Public

    static func readText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// Full HTML document for `markdown`. Local images referenced relative to
    /// `fileURL` are embedded so the page needs no file access to display them.
    static func htmlDocument(markdown: String, fileURL: URL?) -> String {
        var body = renderBody(markdown)
        body = inlineLocalImages(in: body, baseDirectory: fileURL?.deletingLastPathComponent())
        let css = resource("style", "css") ?? ""
        let title = escapeHTML(fileURL?.lastPathComponent ?? "Markdown")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>\(css)</style>
        </head>
        <body>
        <article class="markdown-body">
        \(body)
        </article>
        </body>
        </html>
        """
    }

    // MARK: - Markdown -> HTML

    private static func renderBody(_ markdown: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = context() else {
            return "<pre>" + escapeHTML(markdown) + "</pre>"
        }
        ctx.exception = nil
        let result = ctx.objectForKeyedSubscript("renderMarkdown")?
            .call(withArguments: [convertFrontMatter(markdown)])
        if ctx.exception == nil, let html = result?.toString(), result?.isString == true {
            return html
        }
        return "<pre>" + escapeHTML(markdown) + "</pre>"
    }

    private static func context() -> JSContext? {
        if let c = cachedContext { return c }
        guard let source = resource("marked.min", "js"), let ctx = JSContext() else { return nil }
        ctx.evaluateScript("var self = this; var window = this;")
        ctx.evaluateScript(source)
        ctx.evaluateScript("""
        function slugify(text, seen) {
            var base = text.toLowerCase().trim()
                .replace(/<[^>]+>/g, '')
                .replace(/&[a-z0-9#]+;/g, '')
                .replace(/[^\\p{L}\\p{N}\\s_-]/gu, '')
                .replace(/\\s+/g, '-');
            var slug = base, n = 1;
            while (seen[slug]) { slug = base + '-' + (n++); }
            seen[slug] = true;
            return slug;
        }
        var __seen = {};
        marked.use({
            gfm: true,
            renderer: {
                heading: function (token) {
                    var inner = this.parser.parseInline(token.tokens);
                    var id = slugify(token.text || '', __seen);
                    return '<h' + token.depth + ' id="' + id + '">' + inner + '</h' + token.depth + '>\\n';
                }
            }
        });
        function renderMarkdown(src) {
            __seen = {};
            return marked.parse(src);
        }
        """)
        guard ctx.exception == nil else { return nil }
        cachedContext = ctx
        return ctx
    }

    /// YAML front matter would otherwise render as a stray rule and heading.
    private static func convertFrontMatter(_ markdown: String) -> String {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.hasPrefix("---\n") else { return text }
        let rest = text.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") ?? (rest.hasSuffix("\n---") ? rest.range(of: "\n---", options: .backwards) : nil)
        else { return text }
        let yaml = rest[rest.startIndex..<end.lowerBound]
        let remainder = rest[end.upperBound...]
        return "```yaml\n\(yaml)\n```\n\n\(remainder)"
    }

    // MARK: - Images

    private static let imgRegex = try! NSRegularExpression(
        pattern: #"(<img\b[^>]*?\ssrc\s*=\s*)(["'])(.*?)\2"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    private static func inlineLocalImages(in html: String, baseDirectory: URL?) -> String {
        let ns = NSMutableString(string: html)
        let matches = imgRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let src = ns.substring(with: m.range(at: 3))
            guard let dataURI = dataURI(forImageSource: src, baseDirectory: baseDirectory) else { continue }
            ns.replaceCharacters(in: m.range(at: 3), with: dataURI)
        }
        return ns as String
    }

    private static func dataURI(forImageSource rawSrc: String, baseDirectory: URL?) -> String? {
        var src = rawSrc.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
        guard !src.isEmpty, !src.hasPrefix("#"), !src.hasPrefix("//") else { return nil }

        var fileURL: URL?
        let lower = src.lowercased()
        if lower.hasPrefix("file://") {
            fileURL = URL(string: src)
        } else if lower.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: .regularExpression) != nil {
            return nil // http, https, data, cid, ...
        } else {
            // Drop any ?query or #fragment, then undo percent-encoding.
            if let i = src.firstIndex(where: { $0 == "?" || $0 == "#" }) { src = String(src[..<i]) }
            let path = src.removingPercentEncoding ?? src
            if path.hasPrefix("/") {
                fileURL = URL(fileURLWithPath: path)
            } else if path.hasPrefix("~") {
                fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            } else if let base = baseDirectory {
                fileURL = URL(fileURLWithPath: path, relativeTo: base)
            }
        }
        guard let url = fileURL?.standardizedFileURL,
              let mime = mimeType(forExtension: url.pathExtension.lowercased()),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= maxInlineImageBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func mimeType(forExtension ext: String) -> String? {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg", "jpe": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        case "avif": return "image/avif"
        case "ico": return "image/x-icon"
        case "apng": return "image/apng"
        default: return nil
        }
    }

    // MARK: - Helpers

    private static func resource(_ name: String, _ ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
