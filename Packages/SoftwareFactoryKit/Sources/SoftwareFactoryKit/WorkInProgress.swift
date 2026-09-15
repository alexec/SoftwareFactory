import Foundation

/// What is being worked on right now, across every project, on one page.
///
/// The floor answers "who is here" and each project answers "what is left", but the
/// question between them, what is actually underway, could only be answered by opening
/// every project in turn. (T287, Alex, 15 Sep 2026.)
public enum WorkInProgress {
    public struct Row: Identifiable, Hashable, Sendable {
        public var task: FactoryTask
        /// The project it belongs to, as a person reads it.
        public var projectName: String
        /// The agent on it, by name, or nothing when nobody is.
        public var agentLabel: String?
        /// When it was last touched, which for a task in progress is when it was claimed
        /// or last said something about itself.
        public var since: Date

        public var id: UUID { task.id }

        /// A task in progress with nobody on it is the one to look at: an agent took it
        /// and then stopped, or was deleted, and the task has been sitting in progress
        /// ever since with nobody coming back to it.
        public var nobodyOnIt: Bool { agentLabel == nil }

        public init(task: FactoryTask, projectName: String, agentLabel: String?, since: Date) {
            self.task = task
            self.projectName = projectName
            self.agentLabel = agentLabel
            self.since = since
        }
    }

    /// One row per task in progress, on every project that is still here. The ones
    /// nobody is on come first, then the longest running, because both are read the
    /// same way: this has been going a while, does somebody want to look at it.
    public static func rows(in snapshot: Snapshot) -> [Row] {
        let projects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
        let agents = Dictionary(uniqueKeysWithValues: snapshot.agents.map { ($0.id, $0) })
        let rows = snapshot.tasks.compactMap { task -> Row? in
            guard task.state == .inProgress, task.removed == nil,
                  let project = projects[task.projectID], project.removed == nil else { return nil }
            return Row(
                task: task,
                projectName: project.name,
                agentLabel: task.agentID.flatMap { agents[$0] }?.label,
                since: task.updated)
        }
        return rows.sorted { a, b in
            if a.nobodyOnIt != b.nobodyOnIt { return a.nobodyOnIt }
            return a.since < b.since
        }
    }

    /// How many are in progress with nobody on them. This is the number worth putting
    /// beside the row in the sidebar: a badge that only ever says how much work is
    /// underway is one nobody opens.
    public static func orphaned(in snapshot: Snapshot) -> Int {
        rows(in: snapshot).count(where: \.nobodyOnIt)
    }
}
