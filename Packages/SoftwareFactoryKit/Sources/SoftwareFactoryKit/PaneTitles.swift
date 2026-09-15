import Foundation

/// What tmux says each session's pane is called.
///
/// An OSC title only reaches this app as bytes while it is attached to that session, and
/// most agents work with nobody looking at them, so a card's line would say whatever it
/// last said while its page was open. Unlike a bell, a title is state rather than an
/// event: tmux keeps the last one the agent set, so there is nothing to hook and one ask
/// catches up every session at once, attached or not. (Alex, 15 Sep 2026.)
public enum PaneTitles {
    /// One session, and the title its pane is showing if it has set one.
    public struct Line: Sendable, Equatable {
        public let session: String
        public let title: String?

        public init(session: String, title: String?) {
            self.session = session
            self.title = title
        }
    }

    /// `list-sessions` output: the session name, a tab, then the title. A session that
    /// has not set one comes back with no title rather than an empty one, because an
    /// agent that has not spoken yet must not blank the line its card already shows.
    /// A title may hold anything a terminal may print, tabs included, so only the first
    /// tab separates.
    public static func parse(_ text: String) -> [Line] {
        text.split(separator: "\n").compactMap { row in
            let parts = row.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let session = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !session.isEmpty else { return nil }
            let raw = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return Line(session: session, title: raw.isEmpty ? nil : raw)
        }
    }
}
