import Foundation
import UniformTypeIdentifiers

/// Markdown → HTML using a small built-in renderer (headings, emphasis, code, links, images, lists, quotes, rules).
struct MarkdownConverter: Converter {
    let id = "markdown"
    var inputTypes: [UTType] { [UTType("net.daringfireball.markdown")].compactMap { $0 } }

    func outputFormats(for input: UTType) -> [OutputFormat] { [.html] }

    func convert(
        input: URL, to format: OutputFormat, output: OutputReservation,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let data = try? Data(contentsOf: input), let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ConversionError.unreadableInput
        }
        let title = input.deletingPathExtension().lastPathComponent
        let html = Self.document(markdown: source, title: title)
        let out = try output.reserveFile(ext: "html")
        try html.write(to: out, atomically: true, encoding: .utf8)
        progress(1)
        return out
    }

    // MARK: Rendering

    static func document(markdown: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escape(title))</title>
        <style>body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:46em;margin:2em auto;padding:0 1em;line-height:1.55}code,pre{font-family:Menlo,monospace;background:#f3f3f3}code{padding:.1em .3em;border-radius:3px}pre{padding:1em;overflow:auto}blockquote{border-left:4px solid #ddd;margin-left:0;padding-left:1em;color:#555}img{max-width:100%}</style>
        </head>
        <body>
        \(render(markdown))
        </body>
        </html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func render(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var html: [String] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                html.append("<p>" + inline(paragraph.joined(separator: "\n")) + "</p>")
                paragraph.removeAll()
            }
        }
        func matches(_ line: String, _ pattern: String) -> Bool {
            line.range(of: pattern, options: .regularExpression) != nil
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                html.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>")
                i += 1
                continue
            }
            if trimmed.isEmpty { flushParagraph(); i += 1; continue }
            if matches(trimmed, "^(-{3,}|\\*{3,}|_{3,})$") { flushParagraph(); html.append("<hr>"); i += 1; continue }
            if let range = trimmed.range(of: "^#{1,6} ", options: .regularExpression) {
                flushParagraph()
                let level = trimmed.distance(from: trimmed.startIndex, to: range.upperBound) - 1
                let text = trimmed[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                html.append("<h\(level)>\(inline(text))</h\(level)>")
                i += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                html.append("<blockquote>" + render(quote.joined(separator: "\n")) + "</blockquote>")
                continue
            }
            let unordered = "^\\s*[-*+] +"
            let ordered = "^\\s*\\d+[.)] +"
            if matches(line, unordered) || matches(line, ordered) {
                flushParagraph()
                let isOrdered = matches(line, ordered)
                let pattern = isOrdered ? ordered : unordered
                var items: [String] = []
                while i < lines.count, matches(lines[i], pattern) {
                    let l = lines[i]
                    let r = l.range(of: pattern, options: .regularExpression)!
                    items.append("<li>" + inline(String(l[r.upperBound...])) + "</li>")
                    i += 1
                }
                let tag = isOrdered ? "ol" : "ul"
                html.append("<\(tag)>" + items.joined() + "</\(tag)>")
                continue
            }
            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return html.joined(separator: "\n")
    }

    static func inline(_ text: String) -> String {
        var codeSpans: [String] = []
        var s = escape(text)
        // Protect code spans from further formatting.
        s = replace(s, #"`([^`]+)`"#) { m in
            codeSpans.append("<code>" + m[1] + "</code>")
            return "\u{1}\(codeSpans.count - 1)\u{2}"
        }
        s = replace(s, #"!\[([^\]]*)\]\(([^)\s]+)\)"#) { "<img alt=\"\($0[1])\" src=\"\($0[2])\">" }
        s = replace(s, #"\[([^\]]+)\]\(([^)\s]+)\)"#) { "<a href=\"\($0[2])\">\($0[1])</a>" }
        s = replace(s, #"\*\*(.+?)\*\*"#) { "<strong>\($0[1])</strong>" }
        s = replace(s, #"__(.+?)__"#) { "<strong>\($0[1])</strong>" }
        s = replace(s, #"(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?![*\w])"#) { "<em>\($0[1])</em>" }
        s = replace(s, #"(?<![_\w])_(?!\s)(.+?)(?<!\s)_(?![_\w])"#) { "<em>\($0[1])</em>" }
        s = replace(s, "\u{1}(\\d+)\u{2}") { codeSpans[Int($0[1])!] }
        return s.replacingOccurrences(of: "\n", with: " ")
    }

    private static func replace(_ s: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { idx -> String in
                let r = match.range(at: idx)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
