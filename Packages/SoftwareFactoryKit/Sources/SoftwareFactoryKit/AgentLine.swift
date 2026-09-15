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
