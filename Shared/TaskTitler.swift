import Foundation
import SoftwareFactoryKit

/// Turns what was typed or dictated into a task: its first line is the title, kept
/// exactly as said; anything after that line is the note. (Alex, 12 Sep 2026: the
/// on-device model's title extraction was unreliable enough to be worse than the words
/// themselves — removed rather than patched.)
enum TaskTitler {
    struct Result: Equatable {
        var title: String
        var kind: FactoryTask.Kind
        var note: String
    }

    static func draft(from text: String) async -> Result {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newline = text.firstIndex(where: \.isNewline) else {
            return Result(title: text, kind: .feature, note: "")
        }
        let title = String(text[..<newline]).trimmingCharacters(in: .whitespaces)
        let rest = String(text[text.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(title: title, kind: .feature, note: rest)
    }
}
