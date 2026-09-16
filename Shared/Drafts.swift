import Foundation
import Observation

/// What was typed and not sent, kept so it is still there when you come back.
///
/// Type half a sentence to an agent, go and look something up, come back: it had gone.
/// The field's text was view state and lived exactly as long as the view did, which on
/// this floor is no time at all, because the Debug app is rebuilt and relaunched at the
/// end of every task.
///
/// **Kept across a relaunch**, which was the question on the card. The argument against is
/// a week-old sentence appearing under an agent you have forgotten; the argument for is
/// that this app restarts a dozen times a day, so a draft that does not survive that is a
/// draft that never survives anything. A stale sentence is visible in a box you can see
/// and delete; a lost one is not. (T429, Alex, 15 Sep 2026.)
///
/// **One draft per key, and the key is the thing being written to.** Two agents' pages are
/// two conversations, and carrying words from one into the other would be worse than
/// losing them.
@Observable
@MainActor
final class Drafts {
    /// One holder for both apps and every field. It is where unsent words live, which is
    /// not something either app owns a second copy of.
    static let shared = Drafts()

    private var kept: [String: String]

    private static let key = "drafts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        kept = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    private let defaults: UserDefaults

    /// What is waiting to be sent to this agent, or on this project's add row.
    static func agent(_ id: UUID) -> String { "agent:\(id.uuidString)" }
    static func adding(to projectID: String) -> String { "add:\(projectID)" }

    func text(for key: String) -> String { kept[key] ?? "" }

    func keep(_ text: String, for key: String) {
        let text = text
        if text.isEmpty {
            guard kept[key] != nil else { return }
            kept[key] = nil
        } else {
            guard kept[key] != text else { return }
            kept[key] = text
        }
        defaults.set(kept, forKey: Self.key)
    }

    /// Sent, so it is not a draft any more.
    func clear(_ key: String) { keep("", for: key) }
}
