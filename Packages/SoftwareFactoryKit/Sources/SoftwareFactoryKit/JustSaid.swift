import Foundation

/// What a person has just said to an agent, held only until the daemon's own record shows
/// it.
///
/// Press Send and the words go off to the daemon, which writes them into
/// `transcripts/<agent>.jsonl`; the page shows them when it next folds that file. That is
/// a wait of up to the app's own refresh, and in the meantime the words are gone from the
/// field and nowhere else, which reads as a send that did not happen.
///
/// **The echo lives in the app and never in the log.** The file is the daemon's record and
/// the fold is a pure function of it, so an app writing its own guesses into it breaks the
/// one thing that makes a transcript trustworthy. This is the view's own list, matched
/// against the real thing and dropped the moment it lands: one line, not two.
///
/// Matching is on the words, and on how many times those words were already there. Saying
/// "continue" twice in a row is the ordinary case, so a plain contains would drop both
/// echoes when the first one landed. `alreadySaid` is the count at the moment of sending,
/// and the echo goes when the count passes it. (T495.)
public struct JustSaid: Sendable, Equatable {
    /// One thing said, still waiting to appear.
    public struct Words: Identifiable, Sendable, Equatable {
        public var id: UUID
        public var words: String
        /// How many of these same words were in the conversation and the queue when this
        /// was sent. It lands when there is one more than that.
        public var alreadySaid: Int
        /// Why it did not go, for one that did not. An optimistic line that quietly stays
        /// looks exactly like one that landed, which is worse than the wait it replaced.
        public var failed: String?

        public init(id: UUID = UUID(), words: String, alreadySaid: Int, failed: String? = nil) {
            self.id = id
            self.words = words
            self.alreadySaid = alreadySaid
            self.failed = failed
        }

        public var didNotGo: Bool { failed != nil }
    }

    public private(set) var waiting: [Words] = []

    public init() {}

    public var isEmpty: Bool { waiting.isEmpty }

    /// Puts words on the end and answers which one they are, so the answer from the daemon
    /// can be matched back to them.
    ///
    /// `alreadySaid` is `timesSaid(words:in:queued:)` at the moment of sending. Two of the
    /// same words sent before either has landed count each other too, or the second echo
    /// would be waiting on the first one's arrival.
    @discardableResult
    public mutating func add(_ words: String, alreadySaid: Int) -> UUID {
        let mine = waiting.filter { $0.words == words && !$0.didNotGo }.count
        let one = Words(words: words, alreadySaid: alreadySaid + mine)
        waiting.append(one)
        return one.id
    }

    /// It did not go. The words stay on the page saying so rather than disappearing, and
    /// they stop counting towards what is expected to land: anything said after it is now
    /// waiting on one arrival fewer, or it would sit there for an echo that is never coming.
    public mutating func failed(_ id: UUID, why: String) {
        guard let at = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting[at].failed = why
        let words = waiting[at].words
        for later in waiting.indices where later > at {
            if waiting[later].words == words, !waiting[later].didNotGo {
                waiting[later].alreadySaid -= 1
            }
        }
    }

    /// Takes one off, for words handed back to the person.
    public mutating func drop(_ id: UUID) {
        waiting.removeAll { $0.id == id }
    }

    /// Drops the ones the real record has caught up with. `timesSaid` answers, for some
    /// words, how many of them are now in the conversation and the queue.
    ///
    /// One that did not go is kept whatever the count says: it is there to be read and
    /// taken back, not to be waited on.
    public mutating func settle(_ timesSaid: (String) -> Int) {
        waiting.removeAll { one in
            guard !one.didNotGo else { return false }
            return timesSaid(one.words) > one.alreadySaid
        }
    }

    /// How many times these words are already in an agent's conversation and in what is
    /// queued to be said to it. Both, because a send lands in one place or the other: the
    /// daemon writes it into the log when it goes straight to the agent, and holds it in
    /// the queue when the agent is mid-turn.
    public static func timesSaid(_ words: String, in entries: [ACPTranscript.Entry], queued: [String]) -> Int {
        let said = entries.filter {
            if case .asked(let text) = $0.kind { return text == words }
            return false
        }.count
        return said + queued.filter { $0 == words }.count
    }
}
