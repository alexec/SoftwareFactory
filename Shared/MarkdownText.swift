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
                .font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
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
