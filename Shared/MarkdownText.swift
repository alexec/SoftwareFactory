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
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
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
                Text("•").foregroundStyle(Color(.quiet))
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").foregroundStyle(Color(.quiet)).monospacedDigit()
                inline(text)
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(.tertiary).frame(width: 2)
                inline(text).foregroundStyle(Color(.quiet))
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
        if let attributed = try? AttributedString(
            markdown: words,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(words)
    }
}
