import SwiftUI
import SoftwareFactoryKit

/// A task field that reads Design/Plan/Code/… from the first word, and offers the
/// matching word while you type it. Empty is quiet: it is not a picker.
struct WorkField: View {
    var prompt: String
    @Binding var text: String
    var lineLimit: ClosedRange<Int> = 1...5

    private var prefix: String {
        text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    private var matches: [FactoryTask.Work] {
        FactoryTask.Work.completions(prefix: prefix)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(prompt, text: $text, axis: .vertical)
                .lineLimit(lineLimit)
            if !matches.isEmpty {
                HStack(spacing: 8) {
                    ForEach(matches, id: \.self) { work in
                        Button(work.word) { complete(work) }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Complete \(work.word)")
                    }
                }
            }
        }
    }

    private func complete(_ work: FactoryTask.Work) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let space = trimmed.firstIndex(where: \.isWhitespace) {
            let rest = trimmed[space...].drop(while: \.isWhitespace)
            text = rest.isEmpty ? work.word + " " : "\(work.word) \(rest)"
        } else {
            text = work.word + " "
        }
    }
}
