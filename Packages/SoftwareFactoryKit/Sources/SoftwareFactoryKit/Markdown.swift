import Foundation

/// One piece of a document, in the order it was written. An agent files markdown and the
/// apps show it as markdown; without this a whole plan arrives as one paragraph, because
/// `AttributedString(markdown:)` reads inline marks and throws the line breaks away.
/// (T208.)
public enum MarkdownBlock: Equatable, Sendable {
    /// `#` to `######`. The level is 1 to 6, whatever was written.
    case heading(level: Int, text: String)
    /// Lines that belong together, joined with a space the way markdown joins them.
    case paragraph(String)
    /// `-`, `*` or `+`, and how far it was indented: 0 for the outer list, 1 inside it.
    case bullet(text: String, indent: Int)
    /// `1.`, `2.`, and the number that was written rather than its position.
    case numbered(number: Int, text: String)
    /// `>` quoted lines, joined.
    case quote(String)
    /// A fenced block, kept line for line with its spacing.
    case code([String])
    /// `---`, `***` or `___` on its own.
    case rule
    /// A pipe table: the heading row, then the rows under it. A run of lines is a table
    /// only when the second one is the dashes, which is what tells a table from a line of
    /// prose that happens to start with a pipe.
    ///
    /// The colons that say which way a column is aligned are read and thrown away. They
    /// are the one part of a table that is about how it looks rather than what it says,
    /// and a column centred on paper and not on a card is worse than one never centred.
    case table(head: [String], rows: [[String]])
}

/// Markdown as far as a document on a project needs it: headings, paragraphs, lists,
/// quotes, fenced code and rules. What is inside a line stays markdown for the view to
/// read inline, so bold, links and `code` still work.
public enum Markdown {
    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quoted: [String] = []
        var fenced: [String]?
        /// The pipe lines read so far. A table cannot be told from prose until the line
        /// after the first one has been seen, so they are held here and settled together.
        var piped: [String] = []
        /// Whether the line just read was a list item, so an indented line after it is
        /// the rest of that item rather than a paragraph of its own. Markdown wraps a
        /// long bullet by indenting what follows, and without this a hard-wrapped list
        /// came apart: half the sentence in the bullet, the other half underneath it as
        /// its own paragraph. (T311.)
        var inList = false

        func endParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        func endQuote() {
            if !quoted.isEmpty {
                blocks.append(.quote(quoted.joined(separator: " ")))
                quoted = []
            }
        }
        func endBoth() {
            endParagraph()
            endQuote()
        }
        /// The pipe lines, as a table if they are one and as prose if they are not. Prose
        /// goes back into the paragraph rather than being dropped: a person who wrote a
        /// pipe on purpose still meant the words around it.
        func endTable() {
            guard !piped.isEmpty else { return }
            if let table = table(piped) {
                blocks.append(table)
            } else {
                paragraph.append(contentsOf: piped)
            }
            piped = []
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            // A fence runs until the next one, and everything between it is kept as typed.
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if let lines = fenced {
                    blocks.append(.code(lines))
                    fenced = nil
                } else {
                    endBoth()
                    fenced = []
                }
                continue
            }
            if fenced != nil {
                fenced?.append(raw)
                continue
            }

            // A pipe line waits for the one after it, and every other kind of line settles
            // whatever was waiting before it is read itself.
            if line.hasPrefix("|") {
                // Whatever came before it is finished, so the table lands after it rather
                // than in front of it.
                endBoth()
                inList = false
                piped.append(line)
                continue
            }
            endTable()

            if line.isEmpty {
                endBoth()
                inList = false
                continue
            }
            if isRule(line) {
                endBoth()
                blocks.append(.rule)
                inList = false
                continue
            }
            if let heading = heading(line) {
                endBoth()
                blocks.append(heading)
                inList = false
                continue
            }
            if let quote = quote(line) {
                endParagraph()
                quoted.append(quote)
                inList = false
                continue
            }
            if let bullet = bullet(raw) {
                endBoth()
                blocks.append(bullet)
                inList = true
                continue
            }
            if let numbered = numbered(line) {
                endBoth()
                blocks.append(numbered)
                inList = true
                continue
            }
            // Indented under the list item above it: the rest of that item.
            if inList, raw.first == " " || raw.first == "\t", let last = blocks.indices.last {
                switch blocks[last] {
                case .bullet(let text, let indent):
                    blocks[last] = .bullet(text: text + " " + line, indent: indent)
                    continue
                case .numbered(let number, let text):
                    blocks[last] = .numbered(number: number, text: text + " " + line)
                    continue
                default: break
                }
            }
            inList = false
            endQuote()
            paragraph.append(line)
        }

        if let lines = fenced { blocks.append(.code(lines)) }
        endTable()
        endBoth()
        return blocks
    }

    /// A run of pipe lines as a table, or nil when it is not one.
    ///
    /// The dashes under the heading are what makes it a table. Without that rule a single
    /// line quoting a shell pipe, or a row of a diagram somebody drew, would come out as a
    /// one-cell table with a border around it.
    private static func table(_ lines: [String]) -> MarkdownBlock? {
        guard lines.count >= 2, isDashes(lines[1]) else { return nil }
        let head = cells(lines[0])
        guard !head.isEmpty else { return nil }
        // Short rows are made up to the heading's width, so a row missing its last cell
        // still lines up with the column above it.
        let rows = lines.dropFirst(2).map { line -> [String] in
            var row = cells(line)
            while row.count < head.count { row.append("") }
            return row
        }
        return .table(head: head, rows: Array(rows))
    }

    /// `| --- | :--: |`: every cell dashes, with the colons that say how a column is
    /// aligned allowed and ignored.
    private static func isDashes(_ line: String) -> Bool {
        let cells = cells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// One row split on its pipes, with the pipes at each end taken off. An escaped pipe
    /// is not read: nothing filed here has wanted a pipe inside a cell, and the rule that
    /// would allow it is worth adding when something does.
    private static func cells(_ line: String) -> [String] {
        var text = Substring(line.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("|") { text = text.dropFirst() }
        if text.hasSuffix("|") { text = text.dropLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        for mark in ["-", "*", "_"] where line.allSatisfy({ String($0) == mark }) { return true }
        return false
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = String(line.dropFirst(hashes))
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func quote(_ line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// The raw line, because how far a bullet is indented is the only thing that says
    /// A document in a sentence or two, for the front of a card: enough to tell one
    /// document from another without opening it.
    ///
    /// The marks come off, because a card is not the place to read markdown: a preview
    /// that opens with a hash and a row of asterisks shows how the document was written
    /// rather than what it says. Code blocks and rules are skipped for the same reason.
    /// Nothing is cut mid-word. (T297, Alex, 15 Sep 2026.)
    public static func summary(_ text: String, limit: Int = 240) -> String {
        var said: [String] = []
        var length = 0
        for block in blocks(text) {
            let piece: String
            switch block {
            case .heading(_, let t): piece = t
            case .paragraph(let t), .quote(let t), .bullet(let t, _), .numbered(_, let t): piece = t
            // A table on the front of a card is a grid squeezed into one line of preview,
            // which says how the document was laid out rather than what it says.
            case .code, .rule, .table: continue
            }
            let plain = withoutMarks(piece)
            guard !plain.isEmpty else { continue }
            said.append(plain)
            length += plain.count + 1
            if length >= limit { break }
        }
        return shortened(said.joined(separator: " "), to: limit)
    }

    /// Inline marks off: bold, italic, code and the brackets around a link, keeping the
    /// words the link was written on.
    static func withoutMarks(_ text: String) -> String {
        var out = ""
        var skipping = false
        for character in text {
            switch character {
            case "*", "_", "`": continue
            case "[", "]": continue
            // The address after a link's words is not something to read on a card.
            case "(" where out.hasSuffix(" ") == false && !out.isEmpty: skipping = true
            case ")" where skipping: skipping = false
            default: if !skipping { out.append(character) }
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Cut at a word, not a letter, and say that it was cut.
    static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        guard let space = cut.lastIndex(of: " ") else { return String(cut) + "…" }
        return cut[cut.startIndex..<space].trimmingCharacters(in: .whitespaces) + "…"
    }

    /// whether it is a list inside a list.
    private static func bullet(_ raw: String) -> MarkdownBlock? {
        let spaces = raw.prefix { $0 == " " || $0 == "\t" }.count
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard let mark = line.first, "-*+".contains(mark) else { return nil }
        let rest = String(line.dropFirst())
        guard rest.first == " " else { return nil }
        return .bullet(text: rest.trimmingCharacters(in: .whitespaces), indent: min(spaces / 2, 3))
    }

    private static func numbered(_ line: String) -> MarkdownBlock? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.first == "." || rest.first == ")" else { return nil }
        let words = rest.dropFirst()
        guard words.first == " " else { return nil }
        return .numbered(number: number, text: words.trimmingCharacters(in: .whitespaces))
    }
}
