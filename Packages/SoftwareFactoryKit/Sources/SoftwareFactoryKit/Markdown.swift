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

            if line.isEmpty {
                endBoth()
                continue
            }
            if isRule(line) {
                endBoth()
                blocks.append(.rule)
                continue
            }
            if let heading = heading(line) {
                endBoth()
                blocks.append(heading)
                continue
            }
            if let quote = quote(line) {
                endParagraph()
                quoted.append(quote)
                continue
            }
            if let bullet = bullet(raw) {
                endBoth()
                blocks.append(bullet)
                continue
            }
            if let numbered = numbered(line) {
                endBoth()
                blocks.append(numbered)
                continue
            }
            endQuote()
            paragraph.append(line)
        }

        if let lines = fenced { blocks.append(.code(lines)) }
        endBoth()
        return blocks
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
            case .code, .rule: continue
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
