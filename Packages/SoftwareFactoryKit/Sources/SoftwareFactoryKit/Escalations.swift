import Foundation

/// The rules for showing questions. Open ones are shown in full; answered ones fold to a
/// line, and only the newest few stay in view so a long-lived project's list does not fill
/// with what is settled. The store keeps everything.
public enum Escalations {
    public struct Shown: Equatable, Sendable {
        public var open: [Escalation]
        public var decided: [Escalation]
    }

    /// Open questions oldest first (the one that has waited longest is at the top), then
    /// the newest `recentDecided` answered ones, newest first.
    public static func visible(for projectID: String, in all: [Escalation], recentDecided: Int = 3) -> Shown {
        let mine = all.filter { $0.projectID == projectID }
        let open = mine.filter(\.isOpen).sorted { $0.raised < $1.raised }
        let decided = mine.filter { !$0.isOpen }
            .sorted { ($0.decision?.at ?? $0.raised) > ($1.decision?.at ?? $1.raised) }
            .prefix(recentDecided)
        return Shown(open: open, decided: Array(decided))
    }
}
