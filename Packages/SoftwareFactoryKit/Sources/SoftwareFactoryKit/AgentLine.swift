import Foundation

/// The one line under an agent's name in the sidebar.
///
/// It was the terminal title, which is whatever the CLI happens to be putting in the
/// window: sometimes the work, often the model's own phrasing of a moment ago, and for a
/// shell just the folder. What the person wants off that row is what the agent is doing.
/// So the task it is on comes first, because the factory knows that outright; then the
/// first line of its status report, because that is the agent saying it in its own words;
/// and the terminal title last, for an agent that has neither. (T295, Alex, 15 Sep 2026.)
public enum AgentLine {
    public static func underTheName(task: FactoryTask?, report: Artifact?, title: String) -> String {
        if let task {
            let work = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !work.isEmpty { return work }
        }
        if let report, let said = news(in: report) { return said }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line for every task in an agent's name, or, holding none, the one line it can
    /// say for itself.
    ///
    /// It showed the one task the factory calls current, which for an agent holding three
    /// is two thirds of a lie: the other two are in its name, nobody else may take them,
    /// and the only way to see them was to open its page. A sidebar that says what
    /// everybody is holding is how you notice one agent holding four. Order is the
    /// backlog's own, blocked first, so the one that is stuck is the one you read.
    /// (T362, Alex, 16 Sep 2026.)
    public struct Line: Identifiable, Hashable, Sendable {
        /// The task's number, "T362", or nothing when the line is not a task.
        public var number: String?
        public var words: String
        public var id: String { (number ?? "") + words }

        public init(number: String?, words: String) {
            self.number = number
            self.words = words
        }
    }

    public static func linesUnderTheName(
        tasks: [FactoryTask], report: Artifact?, title: String
    ) -> [Line] {
        let held = tasks.compactMap { task -> Line? in
            let words = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return nil }
            return Line(number: task.label, words: words)
        }
        if !held.isEmpty { return held }
        let said = underTheName(task: nil, report: report, title: title)
        return said.isEmpty ? [] : [Line(number: nil, words: said)]
    }

    /// The first thing a report actually says. A report's title is usually its own name,
    /// which tells the row nothing, so the body's first real line is the news and the
    /// title is only the fallback. Markdown marks are taken off the front: a row that
    /// begins with a hash is a row that shows how it was written rather than what it says.
    static func news(in report: Artifact) -> String? {
        for row in report.body.split(whereSeparator: \.isNewline) {
            let line = String(row)
                .trimmingCharacters(in: .whitespaces)
                .drop { $0 == "#" || $0 == ">" || $0 == "-" || $0 == "*" || $0 == " " }
            let said = String(line).trimmingCharacters(in: .whitespaces)
            if !said.isEmpty { return said }
        }
        let title = report.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}
