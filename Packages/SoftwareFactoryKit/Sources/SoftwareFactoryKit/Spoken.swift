import Foundation

/// What the factory makes of a sentence somebody said to it.
///
/// Recognition is Apple's, on this device, through `SpeechAnalyzer`. What the words mean
/// is worked out here, with rules, and not by a model. Two attempts at putting a model
/// between Alex and his own words have already been backed out of this app: dictation
/// came off the add rows in T91, and `TaskTitler` dropped Apple Intelligence's title
/// extraction because it was worse than the words themselves. The rules have something a
/// model does not: `Projects.nearMiss` was written for typing slips, and a recogniser
/// makes the same shape of mistake, so it already knows "NightSleeper" is "Sleeper
/// Train".
///
/// Nothing here files anything. It answers what it thinks you meant, and the app shows
/// that as a row you can correct before it happens. A misheard project name that quietly
/// files work on the wrong backlog is worse than typing it yourself, because you do not
/// find out for a week. (T340, and design/dictation.md.)
public enum Spoken {
    /// What was understood: which project, and what to file on it.
    public struct Heard: Equatable, Sendable {
        /// The project, when the words named one or the person was looking at one.
        public var projectID: String?
        /// Its name, for the row to show.
        public var projectName: String?
        /// Whether the project came out of the words rather than off the page. What the
        /// person said wins, and the row says which it was.
        public var projectWasSaid: Bool
        /// What to put on the backlog: the first sentence of what is left, as it was
        /// said. Nothing is rewritten.
        public var title: String
        /// Everything that was said, less the naming of the project. The whole of it goes
        /// in the task's note, so a bad split loses nothing.
        public var said: String

        public var isComplete: Bool { projectID != nil && !title.isEmpty }
    }

    /// Words that lead into a project's name and carry no meaning without it. Used to
    /// judge whether a sentence is only naming the project.
    static let leadIns = ["for", "on", "in", "to", "onto", "at", "the", "a", "an",
                          "project", "add", "task", "new", "please", "um", "er", "so",
                          "okay", "ok", "right", "and", "also"]

    /// The words that introduce a project rather than make a phrase of it. "On Sleeper
    /// Train, fix the timetable" names the project; "the Sleeper Train timetable is
    /// wrong" is a sentence about a timetable, and cutting the name out of it leaves
    /// nonsense. The difference is a preposition against an article. (T351.)
    static let prepositions = ["for", "on", "in", "to", "onto", "at"]

    public static func heard(
        _ said: String, projects: [Project], lookingAt: String? = nil
    ) -> Heard {
        let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        let live = projects.filter { $0.removed == nil }
        var project: Project?
        var left = text

        if let found = named(in: text, among: live) {
            project = found.project
            left = found.rest
        } else if let lookingAt {
            project = live.first { $0.id == lookingAt }
        }

        return Heard(
            projectID: project?.id, projectName: project?.name,
            projectWasSaid: project != nil && left != text,
            title: firstSentence(of: left), said: left)
    }

    /// What is on the row while somebody is still talking: the project, and the words of
    /// the task so far.
    ///
    /// One row rather than two screens. It used to listen on one view and then show what
    /// it understood on another, so you said your piece to a box that was about to be
    /// replaced, and a second thought after the pause had nowhere to go. Now the words
    /// land in the task as they are recognised and you can correct them where they are.
    /// (T363, Alex, 16 Sep 2026.)
    public struct Settling: Equatable, Sendable {
        public var projectID: String?
        /// Whether that project came out of the words just now, rather than being the one
        /// already on the row. Only then have the words changed underneath.
        public var projectWasSaid: Bool
        public var words: String

        public init(projectID: String?, projectWasSaid: Bool, words: String) {
            self.projectID = projectID
            self.projectWasSaid = projectWasSaid
            self.words = words
        }
    }

    /// What a pause settles. Naming a project wins whenever it happens, whatever was on
    /// the row before: saying the name is the one way to put work somewhere other than
    /// the page you are looking at, and it has to work on the second sentence as well as
    /// the first. Naming none leaves everything alone, so a pause mid-thought costs
    /// nothing.
    ///
    /// The naming comes out of the words only where `named` would take it out: at one
    /// end, or a sentence that is only the name. In the middle of a sentence it routes
    /// the task and the words are left as they were said.
    public static func settling(
        _ words: String, projects: [Project], project: String?
    ) -> Settling {
        let live = projects.filter { $0.removed == nil }
        guard let found = named(in: words, among: live) else {
            return Settling(projectID: project, projectWasSaid: false, words: words)
        }
        return Settling(projectID: found.project.id, projectWasSaid: true, words: found.rest)
    }

    /// Words landing in the task as they are recognised. Joined with a space, and nothing
    /// is rewritten: not the capital at the front, not the stop at the end. Every edit to
    /// what somebody said is a chance to make a transcription worse. (T351, T363.)
    public static func appended(_ words: String, _ addition: String) -> String {
        let more = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !more.isEmpty else { return words }
        guard !words.isEmpty else { return more }
        // A field the person left with a space or a newline at the end keeps it: they
        // were making room for what comes next.
        return words.last?.isWhitespace == true ? words + more : words + " " + more
    }

    /// What gets filed, out of the words on the row: a title, and the rest as a note.
    ///
    /// A task is a line and a dictated thought is often several, so the first sentence is
    /// the title and the whole of what was said goes underneath it. Nothing is lost if
    /// that split is wrong. A line break wins over a full stop, because a person who put
    /// one there was saying where the title ends. (T363.)
    public static func filing(_ words: String) -> (title: String, note: String) {
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return ("", "") }
        if let newline = said.firstIndex(where: \.isNewline) {
            let title = String(said[..<newline]).trimmingCharacters(in: .whitespaces)
            let rest = String(said[said.index(after: newline)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (title, rest)
        }
        let title = firstSentence(of: said)
        return (title, title == said ? "" : "Said: \(said)")
    }

    /// The project a sentence names, and what is left once the naming is out of the way.
    ///
    /// The words themselves are not touched beyond that. They were: openers came off the
    /// front, the first letter went up, trailing punctuation went. That is editing what
    /// somebody said, and every edit is a chance to make a transcription worse rather
    /// than better. Cutting a name out of the middle of a sentence is the worst of them,
    /// and it is what turned "For the software factory project. Do not modify the user's
    /// dictated text" into "For the Do not modify the user's dictated text". (T351,
    /// Alex, 15 Sep 2026.)
    ///
    /// So: a sentence that is only naming the project is dropped whole, which is how
    /// people actually say it. A name at the very start or the very end is cut with the
    /// word that led into it, because that leaves the rest whole. A name in the middle of
    /// a sentence is left exactly where it is, and only routes the task.
    static func named(in text: String, among projects: [Project]) -> (project: Project, rest: String)? {
        let sentences = self.sentences(text)

        // A sentence that is only the project's name, said first or last, goes whole.
        for (index, sentence) in sentences.enumerated() where index == 0 || index == sentences.count - 1 {
            guard let found = name(in: words(sentence), among: projects) else { continue }
            var rest = words(sentence)
            rest.removeSubrange(found.range)
            let leftOver = rest.filter { !leadIns.contains(Projects.key($0)) && !Projects.key($0).isEmpty }
            guard leftOver.isEmpty else { continue }
            var kept = sentences
            kept.remove(at: index)
            return (found.project, kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Otherwise the name has to sit at one end of the whole thing to be cut out.
        let all = words(text)
        guard let found = name(in: all, among: projects) else { return nil }
        // At one end means at the end, or one preposition in from it. An article before
        // the name makes it part of the sentence rather than the sentence's subject.
        let leadsIn = { (index: Int) in
            all.indices.contains(index) && prepositions.contains(Projects.key(all[index]))
        }
        let atStart = found.range.lowerBound == 0
            || (found.range.lowerBound == 1 && leadsIn(0))
        let atEnd = found.range.upperBound == all.count
            || (found.range.upperBound == all.count - 1 && leadsIn(all.count - 1))
        guard atStart || atEnd else {
            // Said in the middle of a sentence. It routes the task and nothing is cut.
            return (found.project, text)
        }
        var rest = all
        rest.removeSubrange(found.range)
        trimJoiner(&rest, at: found.range.lowerBound)
        return (found.project, rest.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The title: the first sentence of what is left. Nothing is rewritten; the whole of
    /// what was said goes in the note, so if this split is wrong the words are still
    /// there. A task is a line and a dictated thought is often several.
    public static func firstSentence(of text: String) -> String {
        sentences(text).first ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sentences, kept with their punctuation.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { out.append(piece) }
                current = ""
            }
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { out.append(last) }
        return out
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
    }

    /// Where a project's name sits in what was said, and which project it is.
    ///
    /// Compared with the spaces and punctuation taken out, so "Corpo speak" finds
    /// Corpospeak and "sleeper train," finds Sleeper Train.
    ///
    /// Two passes, and the order is the whole of it. A run of words that is exactly a
    /// project's name wins, longest first, so a name containing another project's name
    /// is not lost to it. Only when nothing matches exactly does it fall back to
    /// `Projects.nearMiss`, which is what makes a misheard name work, and there the run
    /// has to be about as long as the name it matched: nearMiss counts one string
    /// containing the other as a near miss, so without that "Sleeper Train fix" would
    /// match Sleeper Train and swallow the first word of the task.
    static func name(
        in words: [String], among projects: [Project]
    ) -> (project: Project, range: Range<Int>)? {
        if let exact = match(in: words, among: projects, loosely: false) { return exact }
        return match(in: words, among: projects, loosely: true)
    }

    private static func match(
        in words: [String], among projects: [Project], loosely: Bool
    ) -> (project: Project, range: Range<Int>)? {
        guard !words.isEmpty else { return nil }
        var best: (project: Project, range: Range<Int>)?
        for length in 1...min(5, words.count) {
            for start in 0...(words.count - length) {
                let run = words[start..<(start + length)].joined(separator: " ")
                let key = Projects.key(run)
                guard key.count >= (loosely ? 5 : 3) else { continue }
                let project: Project?
                if loosely {
                    // The words as said, not the folded key: nearMiss splits camel case
                    // to find a shared word, so "NightSleeper" has to reach it whole.
                    project = Projects.nearMiss(run, in: projects).flatMap { found in
                        // About as long as the name it matched, or it is a phrase that
                        // happens to contain one rather than somebody saying one.
                        abs(Projects.key(found.name).count - key.count) <= 2 ? found : nil
                    }
                } else {
                    project = projects.first { Projects.key($0.name) == key }
                }
                guard let project else { continue }
                let range = start..<(start + length)
                if best == nil || range.count > best!.range.count { best = (project, range) }
            }
        }
        return best
    }

    /// The "on" in "on Sleeper Train", once the name itself has gone. Looked for on
    /// either side, because the name can come first: "Sleeper Train, fix the timetable".
    static func trimJoiner(_ words: inout [String], at index: Int) {
        if index > 0, prepositions.contains(Projects.key(words[index - 1])) {
            words.remove(at: index - 1)
        } else if index < words.count, prepositions.contains(Projects.key(words[index])) {
            words.remove(at: index)
        }
    }

}
