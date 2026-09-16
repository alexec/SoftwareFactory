import Foundation

/// A document as a page, rather than as a run of text views.
///
/// Everything a person reads on this floor is markdown when it is written: a brief, a
/// plan, a finding, a status report. It is a web page when it is read, and one renderer
/// does all of them, so a note an agent typed, a page on the web and a file in the repo
/// come out looking the same. The styling is paper: a warm ground, a serif, a line
/// length you can read to the end of. (T311.)
public enum Paper {
    /// The markdown as an HTML fragment: no document around it, nothing styled.
    public static func html(_ markdown: String) -> String {
        var out: [String] = []
        var bullets: [MarkdownBlock] = []
        var numbers: [MarkdownBlock] = []

        func endBullets() {
            guard !bullets.isEmpty else { return }
            out.append(list(bullets))
            bullets = []
        }
        func endNumbers() {
            guard !numbers.isEmpty else { return }
            let start = numbers.first.flatMap { block -> Int? in
                if case .numbered(let n, _) = block { return n }
                return nil
            } ?? 1
            let items = numbers.map { block -> String in
                if case .numbered(_, let text) = block { return "<li>\(inline(text))</li>" }
                return ""
            }
            out.append("<ol start=\"\(start)\">\(items.joined())</ol>")
            numbers = []
        }
        func endLists() {
            endBullets()
            endNumbers()
        }

        for block in Markdown.blocks(markdown) {
            switch block {
            case .bullet:
                endNumbers()
                bullets.append(block)
            case .numbered:
                endBullets()
                numbers.append(block)
            case .heading(let level, let text):
                endLists()
                out.append("<h\(level)>\(inline(text))</h\(level)>")
            case .paragraph(let text):
                endLists()
                out.append("<p>\(inline(text))</p>")
            case .quote(let text):
                endLists()
                out.append("<blockquote><p>\(inline(text))</p></blockquote>")
            case .code(let lines):
                endLists()
                out.append("<pre><code>\(escaped(lines.joined(separator: "\n")))</code></pre>")
            case .rule:
                endLists()
                out.append("<hr>")
            case .table(let head, let rows):
                endLists()
                out.append(table(head: head, rows: rows))
            }
        }
        endLists()
        return out.joined(separator: "\n")
    }

    /// One markdown document as a whole page on paper.
    public static func page(markdown: String, title: String = "") -> String {
        page(html(markdown), title: title)
    }

    /// An HTML fragment wrapped in a page: the type, the margins and the ground.
    public static func page(_ body: String, title: String = "") -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escaped(title))</title>
        <style>\(style)</style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    /// Nested where the markdown was indented: a list inside a list is a list inside a
    /// list, not a second one underneath.
    private static func list(_ blocks: [MarkdownBlock], depth: Int = 0) -> String {
        var items: [String] = []
        var index = 0
        while index < blocks.count {
            guard case .bullet(let text, let indent) = blocks[index] else { index += 1; continue }
            guard indent <= depth else {
                // Everything further in belongs to the item just written.
                var inner: [MarkdownBlock] = []
                while index < blocks.count, case .bullet(_, let deeper) = blocks[index], deeper > depth {
                    inner.append(blocks[index])
                    index += 1
                }
                let nested = list(inner, depth: depth + 1)
                if items.isEmpty {
                    items.append("<li>\(nested)</li>")
                } else {
                    items[items.count - 1] = String(items[items.count - 1].dropLast("</li>".count)) + nested + "</li>"
                }
                continue
            }
            items.append("<li>\(inline(text))</li>")
            index += 1
        }
        return "<ul>\(items.joined())</ul>"
    }

    /// A table, with what is inside each cell read the way a line is read anywhere else.
    static func table(head: [String], rows: [[String]]) -> String {
        let heading = "<tr>" + head.map { "<th>\(inline($0))</th>" }.joined() + "</tr>"
        let body = rows.map { row in
            "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
        }
        return "<table><thead>\(heading)</thead><tbody>\(body.joined())</tbody></table>"
    }

    /// What is inside a line: bold, italic, `code` and links. Everything else is text,
    /// escaped, so a document that talks about `<div>` says so rather than drawing one.
    static func inline(_ text: String) -> String {
        let characters = Array(text)
        var out = ""
        var i = 0
        while i < characters.count {
            let c = characters[i]

            // A backslash means the next character is itself.
            if c == "\\", i + 1 < characters.count {
                out += escaped(String(characters[i + 1]))
                i += 2
                continue
            }

            if c == "`", let close = find("`", in: characters, from: i + 1) {
                out += "<code>\(escaped(String(characters[(i + 1)..<close])))</code>"
                i = close + 1
                continue
            }

            if c == "[", let shut = find("]", in: characters, from: i + 1),
               shut + 1 < characters.count, characters[shut + 1] == "(",
               let end = find(")", in: characters, from: shut + 2) {
                let words = String(characters[(i + 1)..<shut])
                let href = String(characters[(shut + 2)..<end]).trimmingCharacters(in: .whitespaces)
                if let safe = safeHref(href) {
                    out += "<a href=\"\(escaped(safe))\">\(inline(words))</a>"
                    i = end + 1
                    continue
                }
            }

            // A mark opens emphasis only where markdown says it does: with something
            // other than a space after it, and for an underscore, not in the middle of a
            // word. Otherwise "1 * 2 * 3" comes out italic and so does some_variable_name.
            if c == "*" || c == "_" {
                let strong = i + 1 < characters.count && characters[i + 1] == c
                let mark = strong ? String([c, c]) : String(c)
                let opens = i + mark.count < characters.count
                    && !characters[i + mark.count].isWhitespace
                    && (c == "*" || i == 0 || !(characters[i - 1].isLetter || characters[i - 1].isNumber))
                if opens, let close = find(mark, in: characters, from: i + mark.count),
                   close > i + mark.count, !characters[close - 1].isWhitespace {
                    let inside = String(characters[(i + mark.count)..<close])
                    out += strong ? "<strong>\(inline(inside))</strong>" : "<em>\(inline(inside))</em>"
                    i = close + mark.count
                    continue
                }
            }

            out += escaped(String(c))
            i += 1
        }
        return out
    }

    private static func find(_ mark: String, in characters: [Character], from: Int) -> Int? {
        let wanted = Array(mark)
        guard from >= 0, from <= characters.count else { return nil }
        var i = from
        while i + wanted.count <= characters.count {
            if Array(characters[i..<(i + wanted.count)]) == wanted { return i }
            i += 1
        }
        return nil
    }

    /// Where a link may point. The web, an address, a file, or somewhere in this same
    /// document. A `javascript:` link is not a link, whoever wrote it.
    static func safeHref(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        guard let colon = text.firstIndex(of: ":") else { return text }
        // A scheme has no slash, space or hash in it: "notes/a:b.md" is a path.
        let scheme = text[text.startIndex..<colon].lowercased()
        guard !scheme.contains(where: { $0 == "/" || $0 == "#" || $0 == "?" || $0 == " " }) else { return text }
        return ["http", "https", "mailto", "file"].contains(scheme) ? text : nil
    }

    public static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    /// Paper, in both appearances. The ground is warm rather than white, the type is a
    /// serif at a size you read rather than scan, and the column stops at a measure so a
    /// wide window does not run a sentence off the far side. Dark is ink and paper the
    /// The colours paper is made of, light and dark, in one place.
    ///
    /// A warm near-white ground, a warm near-black ink, and one rust mark.
    ///
    /// Three others were tried on the way here and this is the one Alex picked with all
    /// of them in front of him: cool drafting paper read as technical rather than
    /// readable, and buff manila came out too orange. It is close to what Claude is set
    /// on, and that was weighed and settled rather than overlooked. (Alex, 16 Sep 2026.)
    ///
    /// Written down once, because the documents are HTML in a web view and the agent's
    /// conversation is SwiftUI, and two sources drift the first time either is touched.
    ///
    /// One place, because the documents are HTML in a web view and the agent's page is
    /// SwiftUI, and two sources would have drifted the first time either was touched.
    /// (Alex, 16 Sep 2026: papery, but not Claude papery, and used everywhere.)
    public enum Tone: String, CaseIterable, Sendable {
        /// The ground. Warm, not white.
        case paper
        /// What is written on it.
        case ink
        /// A second voice: a caption, a date, something said quietly.
        case quiet
        /// A third voice, quieter still: a hint, a count, something you read only when
        /// you go looking. The system's `.tertiary` in the theme's own colour.
        case faint
        /// A line across the page.
        case rule
        /// The edge of something sitting on the page.
        case edge
        /// A block set into the page: code, a quote, a tool call.
        case block
        /// The one colour on the page, for a link or a mark.
        case mark
        /// A person is needed. Not a second mark and not a shade of the ground: it is the
        /// loudest thing the app has, and it is spent only on a question waiting, a task
        /// blocked, a report gone stale and an agent asking permission.
        ///
        /// It was `Color.orange` in thirty-three places and in the palette in none, so
        /// nobody was managing it. On dark paper the system's orange washed at 12 percent
        /// sampled `#6F5A43`, which is a warm brown a shade off the ground: the one signal
        /// in the app, drawn so that it read as more paper. This is saturated enough to
        /// survive being a small mark on either ground. (T408, off T395.)
        case alarm

        /// Light, then dark. Six digits, no hash.
        public var hex: (light: String, dark: String) {
            switch self {
            case .paper: ("fbfaf6", "1b1a18")
            case .ink: ("22201c", "e6e1d8")
            case .quiet: ("6d675d", "9c958a")
            case .faint: ("968f83", "77716a")
            case .rule: ("e0dbd0", "35322d")
            case .edge: ("cfc8ba", "45413a")
            case .block: ("f1ede4", "26241f")
            case .mark: ("8a5a2b", "d0a271")
            case .alarm: ("c2410c", "fb923c")
            }
        }
    }

    /// The measure: how wide a line may be before it is hard to find the next one.
    /// 46em of a 15px serif, which is what the documents are set to.
    public static let measure = 690.0

    static var lightTones: String {
        Tone.allCases.map { "--\($0.rawValue): #\($0.hex.light);" }.joined(separator: " ")
    }

    static var darkTones: String {
        Tone.allCases.map { "--\($0.rawValue): #\($0.hex.dark);" }.joined(separator: " ")
    }

    /// other way up, not a white page dimmed.
    static var style: String {
    """
    :root { color-scheme: light dark; \(lightTones) }
    @media (prefers-color-scheme: dark) { :root { \(darkTones) } }
    html { -webkit-text-size-adjust: 100%; background: var(--paper); }
    body { margin: 0 auto; padding: 30px 32px 56px; max-width: 46em; background: var(--paper); \
    color: var(--ink); font: 15px/1.65 ui-serif, "New York", Georgia, "Times New Roman", serif; \
    -webkit-font-smoothing: antialiased; word-wrap: break-word; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.6em 0 0.5em; font-weight: 600; }
    h1 { font-size: 1.7em; margin-top: 0; }
    h2 { font-size: 1.32em; }
    h3 { font-size: 1.12em; }
    h4, h5, h6 { font-size: 1em; }
    body > :first-child { margin-top: 0; }
    p, ul, ol, blockquote, pre, hr, table { margin: 0 0 1em; }
    ul, ol { padding-left: 1.4em; }
    li { margin: 0.25em 0; }
    li > ul, li > ol { margin: 0.25em 0 0.25em; }
    blockquote { margin-left: 0; padding: 0.1em 0 0.1em 1em; border-left: 3px solid var(--edge); \
    color: var(--quiet); font-style: italic; }
    blockquote p { margin: 0.5em 0; }
    a { color: var(--mark); text-decoration: underline; text-underline-offset: 2px; }
    code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.88em; \
    background: var(--block); padding: 0.12em 0.34em; border-radius: 4px; }
    pre { background: var(--block); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
    pre code { background: none; padding: 0; font-size: 0.85em; line-height: 1.5; }
    hr { border: none; border-top: 1px solid var(--rule); margin: 2em 0; }
    img { max-width: 100%; height: auto; }
    table { border-collapse: collapse; }
    td, th { border: 1px solid var(--rule); padding: 4px 8px; text-align: left; }
    th { font-weight: 600; background: var(--block); }
    """
    }
}
