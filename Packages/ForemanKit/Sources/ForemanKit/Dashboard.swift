import Foundation

/// What the dashboard shows, derived from the store and the sessions on disk.
public struct Dashboard: Sendable, Equatable {
    public enum ProjectActivity: String, Sendable {
        /// An agent's transcript changed moments ago.
        case working
        /// An agent is alive on it and quiet: waiting, most likely on you.
        case waiting
        /// No live agent on it.
        case idle
    }

    public struct ProjectStatus: Identifiable, Sendable, Equatable {
        public var project: Project
        public var activity: ProjectActivity
        /// The backlog item marked in progress, when there is one.
        public var currentItem: WorkItem?
        /// The most recently active live session, when there is one.
        public var session: AgentSession?
        public var liveSessions: Int
        public var openEscalations: Int
        public var backlogCount: Int

        public var id: String { project.id }

        /// One line saying what the project is on: the item first, the last prompt otherwise.
        public var doing: String? {
            if let currentItem { return currentItem.title }
            if activity != .idle, let prompt = session?.lastPrompt, !prompt.isEmpty { return prompt }
            return nil
        }
    }

    public var inProgress: Int
    public var openEscalations: [Escalation]
    public var projects: [ProjectStatus]

    public static let empty = Dashboard(inProgress: 0, openEscalations: [], projects: [])

    public var workingCount: Int { projects.filter { $0.activity == .working }.count }
    public var waitingCount: Int { projects.filter { $0.activity == .waiting }.count }

    /// Builds the dashboard. Projects come from the store and from any folder a live
    /// session is in; a session in a scratch workspace is nobody's project and is skipped.
    public static func make(snapshot: Snapshot, sessions: [AgentSession], now: Date = .now) -> Dashboard {
        var projects: [String: Project] = [:]
        for p in snapshot.projects { projects[p.id] = p }
        for s in sessions where s.isLive && !s.isScratch && projects[s.projectID] == nil {
            projects[s.projectID] = Project(path: s.cwd, added: s.startedAt ?? now)
        }

        let statuses = projects.values.map { project -> ProjectStatus in
            let live = sessions.filter { $0.projectID == project.id && $0.isLive }
            let activities = live.map { $0.activity(now: now) }
            let activity: ProjectActivity =
                activities.contains(.working) ? .working : (live.isEmpty ? .idle : .waiting)
            let busiest = live.max { $0.lastActivity < $1.lastActivity }
            let items = snapshot.items.filter { $0.projectID == project.id }
            return ProjectStatus(
                project: project,
                activity: activity,
                currentItem: Backlog.current(for: project.id, in: snapshot.items),
                session: busiest,
                liveSessions: live.count,
                openEscalations: snapshot.escalations.filter { $0.projectID == project.id && $0.isOpen }.count,
                backlogCount: items.filter { $0.state == .backlog }.count
            )
        }
        .sorted { a, b in
            if a.activity != b.activity { return rank(a.activity) < rank(b.activity) }
            return a.project.name.localizedCaseInsensitiveCompare(b.project.name) == .orderedAscending
        }

        return Dashboard(
            inProgress: snapshot.items.filter { $0.state == .inProgress }.count,
            openEscalations: snapshot.escalations.filter(\.isOpen).sorted { $0.raised < $1.raised },
            projects: statuses
        )
    }

    private static func rank(_ a: ProjectActivity) -> Int {
        switch a {
        case .working: 0
        case .waiting: 1
        case .idle: 2
        }
    }
}
