#if os(macOS)
import Foundation

/// Markdown to a styled HTML page, for documents: headings, paragraphs, lists (nested by
/// indent), fenced code with its language, block quotes with NOTE/TIP/WARNING callouts,
/// tables, rules, and inline code, bold, italic and links. Everything is escaped; the page
/// has no script.
enum MarkdownHTML {
    static func page(_ markdown: String, title: String? = nil) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title ?? "Document"))</title><style>\(css)</style></head>
        <body><article>\(body(markdown))</article></body></html>
        """
    }

    /// Words in a document and minutes to read it.
    static func stats(_ markdown: String) -> (words: Int, minutes: Int) {
        let words = markdown.split { $0.isWhitespace || $0.isNewline }.filter { $0.contains(where: \.isLetter) }.count
        return (words, max(1, Int((Double(words) / 220).rounded())))
    }

    /// Its first heading, if it has one.
    static func title(_ markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") { return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    // MARK: Blocks

    static func body(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var html = ""
        var index = 0
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            html += "<p>" + inline(paragraph.joined(separator: " ")) + "</p>\n"
            paragraph = []
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Fenced code.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                let label = language.isEmpty ? "" : "<span class=\"lang\">\(escape(language.uppercased()))</span>"
                html += "<pre>\(label)<code>\(escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }
            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }
            // Headings.
            if let level = headingLevel(trimmed) {
                flush()
                let text = trimmed.dropFirst(level + 1)
                html += "<h\(level) id=\"\(slug(String(text)))\">\(inline(String(text)))</h\(level)>\n"
                index += 1
                continue
            }
            // Rules.
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1, "-*_".contains(trimmed.first ?? " ") {
                flush()
                html += "<hr>\n"
                index += 1
                continue
            }
            // Block quotes and callouts.
            if trimmed.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                html += callout(quote)
                continue
            }
            // Tables: a header row, then a |---| row.
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isDivider(lines[index + 1]) {
                flush()
                let header = cells(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                html += "<table><thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
                html += rows.map { "<tr>" + $0.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }.joined()
                html += "</tbody></table>\n"
                continue
            }
            // Lists.
            if listMarker(line) != nil {
                flush()
                var items: [String] = []
                while index < lines.count {
                    let current = lines[index]
                    if current.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A blank line ends the list unless another item follows.
                        if index + 1 < lines.count, listMarker(lines[index + 1]) != nil { index += 1; continue }
                        break
                    }
                    guard listMarker(current) != nil || current.hasPrefix("  ") else { break }
                    items.append(current)
                    index += 1
                }
                html += list(items)
                continue
            }
            paragraph.append(trimmed)
            index += 1
        }
        flush()
        return html
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func isDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var parts = row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first?.isEmpty == true { parts.removeFirst() }
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    /// "- ", "* ", "+ " or "1. ": ordered or not, its indent, and where the text starts.
    private static func listMarker(_ line: String) -> (ordered: Bool, indent: Int, text: String)? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return (false, indent, String(rest.dropFirst(2)))
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count < 4, rest.dropFirst(digits.count).hasPrefix(". ") {
            return (true, indent, String(rest.dropFirst(digits.count + 2)))
        }
        return nil
    }

    private static func list(_ lines: [String]) -> String {
        guard let first = lines.first.flatMap(listMarker) else { return "" }
        let base = first.indent
        var html = first.ordered ? "<ol>" : "<ul>"
        var index = 0
        while index < lines.count {
            guard let marker = listMarker(lines[index]), marker.indent <= base + 1 else { index += 1; continue }
            var text = marker.text
            var nested: [String] = []
            var blocks = ""
            index += 1
            while index < lines.count {
                let next = lines[index]
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                if listMarker(next) == nil, trimmed.hasPrefix("```") {
                    // A code block inside the item, up to its closing fence.
                    let indent = next.prefix { $0 == " " }.count
                    var fence = [trimmed]
                    index += 1
                    while index < lines.count {
                        let line = lines[index]
                        fence.append(String(line.dropFirst(min(indent, line.prefix { $0 == " " }.count))))
                        index += 1
                        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    }
                    blocks += body(fence.joined(separator: "\n"))
                    continue
                }
                if let inner = listMarker(next), inner.indent > base + 1 {
                    nested.append(next)
                } else if listMarker(next) == nil {
                    text += " " + next.trimmingCharacters(in: .whitespaces)
                } else {
                    break
                }
                index += 1
            }
            // A task list item.
            var box = ""
            if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                box = text.hasPrefix("[ ]") ? "☐ " : "☑ "
                text = String(text.dropFirst(4))
            }
            html += "<li>\(box)\(inline(text))\(blocks)\(nested.isEmpty ? "" : list(nested))</li>"
        }
        return html + (first.ordered ? "</ol>" : "</ul>") + "\n"
    }

    private static func callout(_ lines: [String]) -> String {
        if let first = lines.first, first.hasPrefix("[!"), let end = first.firstIndex(of: "]") {
            let kind = first[first.index(first.startIndex, offsetBy: 2)..<end].lowercased()
            let rest = Array(lines.dropFirst())
            let titles = ["note": "ⓘ NOTE", "tip": "💡 TIP", "important": "! IMPORTANT", "warning": "⚠ WARNING", "caution": "⚠ CAUTION"]
            return "<div class=\"callout \(escape(kind))\"><b>\(titles[kind] ?? kind.uppercased())</b>\(body(rest.joined(separator: "\n")))</div>\n"
        }
        return "<blockquote>\(body(lines.joined(separator: "\n")))</blockquote>\n"
    }

    // MARK: Inline

    static func inline(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "`", let close = text[text.index(after: index)...].firstIndex(of: "`") {
                out += "<code>\(escape(String(text[text.index(after: index)..<close])))</code>"
                index = text.index(after: close)
                continue
            }
            if char == "[", let close = text[index...].firstIndex(of: "]"), text.index(after: close) < text.endIndex,
               text[text.index(after: close)] == "(", let end = closingParen(text, from: text.index(after: close)) {
                let label = String(text[text.index(after: index)..<close])
                let href = String(text[text.index(close, offsetBy: 2)..<end])
                let lower = href.lowercased()
                let safe = lower.hasPrefix("http://") || lower.hasPrefix("https://") || href.hasPrefix("#") ? escape(href) : "#"
                out += "<a href=\"\(safe)\">\(inline(label))</a>"
                index = text.index(after: end)
                continue
            }
            if text[index...].hasPrefix("**"), let close = text[text.index(index, offsetBy: 2)...].range(of: "**") {
                out += "<strong>\(inline(String(text[text.index(index, offsetBy: 2)..<close.lowerBound])))</strong>"
                index = close.upperBound
                continue
            }
            if char == "*" || char == "_", let close = emphasisEnd(text, at: index) {
                out += "<em>\(inline(String(text[text.index(after: index)..<close])))</em>"
                index = text.index(after: close)
                continue
            }
            out += escape(String(char))
            index = text.index(after: index)
        }
        return out
    }

    /// The ")" matching the "(" at `open`, counting nested ones (URLs can have them).
    private static func closingParen(_ text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 } else if text[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Where `*text*` or `_text_` ends, if the marker at `index` opens one: not inside a word
    /// (so my_module_name and 5*3 stay as they are), and not followed by a space.
    private static func emphasisEnd(_ text: String, at index: String.Index) -> String.Index? {
        let marker = text[index]
        let start = text.index(after: index)
        guard start < text.endIndex, !text[start].isWhitespace, text[start] != marker else { return nil }
        if index > text.startIndex, text[text.index(before: index)].isLetter || text[text.index(before: index)].isNumber { return nil }
        var search = start
        while let close = text[search...].firstIndex(of: marker) {
            let after = text.index(after: close)
            let wordAfter = after < text.endIndex && (text[after].isLetter || text[after].isNumber)
            if close > start, !text[text.index(before: close)].isWhitespace, !wordAfter { return close }
            search = after
            if search >= text.endIndex { break }
        }
        return nil
    }

    /// A heading's anchor, for links within the page: "Getting started" → "getting-started".
    static func slug(_ text: String) -> String {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.joined(separator: "-")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Style

    /// A printed page: warm paper, a clear sans face, an orange rule under headings.
    static let css = """
    @page { margin: 18mm 16mm; }
    :root { color-scheme: light; }
    html { background: #f4f1ea; }
    body { margin: 0; padding: 36px 28px 60px; color: #2a2723; font: 15px/1.62 -apple-system, "Helvetica Neue", sans-serif; }
    article { max-width: 760px; margin: 0 auto; background: #fffdf8; padding: 48px 56px; border-radius: 14px;
              box-shadow: 0 1px 2px rgba(0,0,0,.06), 0 8px 28px rgba(0,0,0,.06); }
    h1, h2, h3, h4 { color: #1d1b18; line-height: 1.25; font-weight: 700; }
    h1 { font-size: 30px; margin: 0 0 18px; letter-spacing: -0.01em; }
    h2 { font-size: 21px; margin: 34px 0 12px; }
    h1::after, h2::after { content: ""; display: block; width: 34px; height: 3px; background: #f2602b; border-radius: 2px; margin-top: 9px; }
    h3 { font-size: 17px; margin: 26px 0 8px; }
    p { margin: 0 0 14px; }
    a { color: #c8461a; }
    ul, ol { padding-left: 22px; margin: 0 0 14px; }
    li { margin: 4px 0; }
    ul li::marker { color: #f2602b; }
    ol li::marker { color: #f2602b; font-weight: 600; }
    code { font: 13px ui-monospace, "SF Mono", Menlo, monospace; background: #fbeee6; color: #b4471d; padding: 1px 5px; border-radius: 5px; }
    pre { position: relative; background: #1f1d1b; color: #ece8e1; padding: 16px 18px; border-radius: 10px; overflow-x: auto; margin: 0 0 16px; }
    pre code { background: none; color: inherit; padding: 0; font-size: 12.5px; line-height: 1.55; }
    pre .lang { position: absolute; top: 8px; right: 12px; font: 600 10px -apple-system, sans-serif; letter-spacing: .08em; color: #8b867f; }
    blockquote { margin: 0 0 16px; padding: 4px 16px; border-left: 3px solid #e4ddd1; color: #5d5852; }
    .callout { border-radius: 10px; padding: 12px 16px 2px; margin: 0 0 16px; }
    .callout > b { display: block; font-size: 11px; letter-spacing: .07em; margin-bottom: 6px; }
    .callout.note, .callout.important { background: #fdeee4; } .callout.note > b, .callout.important > b { color: #c8461a; }
    .callout.tip { background: #e8f5e9; } .callout.tip > b { color: #2e7d32; }
    .callout.warning, .callout.caution { background: #fff4d6; } .callout.warning > b, .callout.caution > b { color: #9a6a00; }
    table { border-collapse: collapse; width: 100%; margin: 0 0 18px; font-size: 14px; }
    th { text-align: left; font-size: 11.5px; letter-spacing: .05em; text-transform: uppercase; color: #6d6862; border-bottom: 2px solid #e8e1d6; padding: 8px 10px; }
    td { border-bottom: 1px solid #efe9df; padding: 8px 10px; vertical-align: top; }
    hr { border: 0; border-top: 1px solid #e8e1d6; margin: 28px 0; }
    @media print { html, body { background: #fff; padding: 0; } article { box-shadow: none; padding: 0; max-width: none; } pre { white-space: pre-wrap; } }
    """
}
#endif
