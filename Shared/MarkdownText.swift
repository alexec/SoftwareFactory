import SwiftUI
import SoftwareFactoryKit

/// Markdown as a person reads it: headings that look like headings, lists that line up,
/// code that keeps its shape. An agent files a document in markdown, and before T208 the
/// whole thing arrived as one grey paragraph, because `AttributedString(markdown:)` reads
/// the marks inside a line and throws every line break away. `Markdown.blocks` does the
/// splitting; this draws it.
struct MarkdownText: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownCache.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                // A heading is never smaller than the words under it: the third level was
                // subheadline, which on the Mac is a step below the body around it, so a
                // document read as though its own headings were asides. (T459.)
                .font(level <= 1 ? Style.Text.thing : level == 2 ? Style.Text.rowName : Style.Text.row.weight(.semibold))
                .padding(.top, 2)
        case .paragraph(let text):
            inline(text)
        case .bullet(let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                inline(text)
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(.tertiary).frame(width: 2)
                inline(text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let lines):
            ScrollView(.horizontal) {
                Text(lines.joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .padding(10)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: .rect(cornerRadius: 8))
        case .rule:
            Divider()
        case .table(let head, let rows):
            // A grid rather than a scrolling box: a table filed here is three or four
            // narrow columns, and the ones that are not are better read on paper, which is
            // where a document this long is opened anyway.
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    ForEach(Array(head.enumerated()), id: \.offset) { _, cell in
                        inline(cell).font(.callout.weight(.semibold))
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inline(cell)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Bold, links and `code` inside a line are markdown's own job.
    private func inline(_ words: String) -> Text {
        Text(MarkdownCache.attributed(words))
    }
}

/// Markdown parsed once per piece of text rather than once per redraw.
///
/// `body` runs whenever anything on the screen changes, and the app reloads the store every
/// two seconds, so a conversation of three hundred turns re-read three hundred documents to
/// draw the same words again. Splitting one is cheap and reading the marks inside its lines
/// is not: measured on a real status report of 2,852 characters, 0.03 ms to split and
/// 0.21 ms for the lines. The text is the key because the text is the whole input: these are
/// pure functions, so the same string always folds the same way and a stale answer is not a
/// thing that can happen. (R67, T526.)
///
/// **Main actor rather than a lock.** Every caller is a SwiftUI view body, so there is one
/// thread and nothing to guard against.
///
/// Full is emptied rather than evicted by age. What is wanted is what is on screen, which
/// arrives together and is asked for again on the next redraw, so the cache refills in one
/// pass; keeping a use order to throw away the coldest entry is bookkeeping on every read to
/// save a refill that costs a frame every few thousand documents.
@MainActor
enum MarkdownCache {
    /// Generous enough to hold a long conversation scrolled all the way back, small enough
    /// that a runaway is a few megabytes rather than the store.
    static let room = 4000

    private static var split: [String: [MarkdownBlock]] = [:]
    private static var lines: [String: AttributedString] = [:]

    static func blocks(_ text: String) -> [MarkdownBlock] {
        if let already = split[text] { return already }
        let folded = Markdown.blocks(text)
        if split.count >= room { split.removeAll(keepingCapacity: true) }
        split[text] = folded
        return folded
    }

    static func attributed(_ words: String) -> AttributedString {
        if let already = lines[words] { return already }
        let read = (try? AttributedString(
            markdown: words,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(words)
        if lines.count >= room { lines.removeAll(keepingCapacity: true) }
        lines[words] = read
        return read
    }
}
