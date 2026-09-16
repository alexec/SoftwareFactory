import Foundation

/// Every agent's status report in one place, so the question "what is everyone doing"
/// has somewhere to be answered.
///
/// It was answerable before only by opening each agent's page in turn, which is fine for
/// two agents and useless for eight. The rows carry the agent that has said nothing as
/// well as the ones that have: an agent with no report is the row you most want to see,
/// and leaving it out would make the page quietest exactly where something is wrong.
/// (T288, Alex, 15 Sep 2026.)
public enum StatusReportBoard {
    public struct Row: Identifiable, Hashable, Sendable {
        public var agent: Agent
        /// The project it is on, as a person reads it, or nothing when it is on none.
        public var projectName: String?
        /// That project, as something to open. It travels with the name rather than
        /// being read off the agent, because the two can disagree: an agent keeps the
        /// projectID of a project that has been removed, and clicking through to a
        /// project that is not in `load()` any more opens a page about nothing. (T338.)
        public var projectID: String?
        /// Its report, if it has filed one.
        public var report: Artifact?
        /// Whether that report still stands, or is old enough that the factory has asked
        /// for another. An agent the factory can watch is never stale: its page says what
        /// it is doing, so there is nothing to chase. (T373.)
        public var isFresh: Bool
        /// What it is doing, for an agent whose work the factory can see. This is
        /// `Agent.title`, which the daemon fills from the transcript, and it stands in
        /// for a report that is no longer asked for.
        public var doing: String? {
            guard agent.speaksACP else { return nil }
            let line = agent.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }

        public var id: UUID { agent.id }
        /// When it last said anything about its work. Nil for an agent that never has.
        public var said: Date? { report?.updated }

        public init(
            agent: Agent, projectName: String?, projectID: String? = nil,
            report: Artifact?, isFresh: Bool
        ) {
            self.agent = agent
            self.projectName = projectName
            self.projectID = projectID
            self.report = report
            self.isFresh = isFresh
        }
    }

    /// One row per agent on the floor, the latest news first, and the agents that have
    /// said nothing at the bottom in the order they arrived. Newest first because the
    /// page is read from the top when you want to know what has happened since you last
    /// looked.
    public static func rows(in snapshot: Snapshot, now: Date) -> [Row] {
        let rows = Agents.onTheFloor(snapshot.agents).map { agent -> Row in
            let project = agent.projectID.flatMap { id in
                snapshot.projects.first { $0.id == id && $0.removed == nil }
            }
            let report = agent.projectID.flatMap {
                Artifacts.statusReport(by: agent.id, on: $0, in: snapshot.artifacts)
            }
            return Row(
                agent: agent, projectName: project?.name, projectID: project?.id, report: report,
                // An agent the factory watches is never chased for a report it was never
                // asked for.
                isFresh: agent.speaksACP || (report.map { Artifacts.isFresh($0, now: now) } ?? false))
        }
        return rows.sorted { a, b in
            switch (a.said, b.said) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.agent.registered < b.agent.registered
            }
        }
    }

    /// How many agents on the floor have not said anything recently. This is the number
    /// worth putting on the sidebar row: a page that only ever says how many agents there
    /// are is a page nobody opens.
    public static func quiet(in snapshot: Snapshot, now: Date) -> Int {
        rows(in: snapshot, now: now).filter { !$0.isFresh }.count
    }
}
