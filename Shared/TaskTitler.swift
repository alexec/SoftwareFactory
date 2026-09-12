import Foundation
import FoundationModels
import SoftwareFactoryKit

/// Turns what was typed or dictated into a task: a short title, the kind, and the rest
/// as the note. Apple Intelligence, on device; when it is not available the words are
/// the title, which is what they were before.
enum TaskTitler {
    @Generable(description: "A task for a software project's backlog.")
    struct Drafted {
        @Guide(description: "What should be done, as an instruction starting with a verb, under twelve words, no full stop.")
        var title: String
        @Guide(description: "feature, bug or chore")
        var kind: String
        @Guide(description: "Anything said that the title does not carry, or empty.")
        var note: String
    }

    struct Result: Equatable {
        var title: String
        var kind: FactoryTask.Kind
        var note: String
    }

    static let instructions = """
        You turn one dictated or typed sentence into a task for a software project's \
        backlog. The title says what should be done, as a short instruction starting with a \
        verb, so that someone who reads only the title knows the whole task: never a single \
        word, never a label, never a summary that drops the point. Use the person's own \
        words; never introduce a name, a term or jargon they did not say. Say whether it is \
        a feature (something new), a bug (something wrong) or a chore (upkeep). Keep in the \
        note only what the title leaves out, or nothing. Do not invent anything.
        """

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Short text is already a title; only longer text is worth a model's time.
    static func draft(from text: String) async -> Result {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = Result(title: text, kind: .feature, note: "")
        guard text.count > 40 || text.contains("."), isAvailable else { return plain }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: text, generating: Drafted.self)
            let d = response.content
            let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !title.isEmpty else { return plain }
            return Result(title: title, kind: FactoryTask.Kind(rawValue: d.kind.lowercased()) ?? .feature,
                          note: d.note.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return plain
        }
    }
}
