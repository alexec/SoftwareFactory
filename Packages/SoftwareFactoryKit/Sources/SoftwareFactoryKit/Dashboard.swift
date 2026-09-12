import Foundation

/// What the floor shows, derived from the store.
public struct Dashboard: Sendable, Equatable {
    public enum ProjectActivity: String, Sendable {
        /// An agent on it checked in moments ago.
        case working
        /// An agent is on it and quiet, or has a question open.
        case waiting
        /// No agent on it.
        case idle
    }

    public struct ProjectStatus: Identifiable, Sendable, Equatable {
        public var project: Project
        public var activity: ProjectActivity
        public var currentTask: FactoryTask?
        public var agents: [Agent]
        public var openEscalations: Int
        public var backlogCount: Int
        public var blockedCount: Int
        public var inProgressCount: Int
        public var doneCount: Int

        public var id: String { project.id }

        /// One line saying what the project is on. Nothing while on hold.
        public var doing: String? {
            if project.onHold { return nil }
            if let currentTask { return currentTask.title }
            if let note = agents.first?.note, !note.isEmpty { return note }
            return nil
        }
    }

    public struct AgentStatus: Identifiable, Sendable, Equatable {
        public var agent: Agent
        public var project: Project?
        public var task: FactoryTask?
        public var isWorking: Bool
        public var waitingOnYou: Bool

        public var id: UUID { agent.id }
    }

    public struct Holding: Identifiable, Sendable, Equatable {
        public var lease: Lease
        public var agentName: String
        /// Past its time, holder still on the floor.
        public var isOverdue: Bool

        public var id: UUID { lease.id }
    }

    public struct ResourceStatus: Identifiable, Sendable, Equatable {
        public var resource: Resource
        public var held: [Holding]

        public var id: UUID { resource.id }
        public var free: Int { max(0, resource.slots - held.count) }
    }

    public var inProgress: Int
    public var openEscalations: [Escalation]
    public var projects: [ProjectStatus]
    public var agents: [AgentStatus]
    public var resources: [ResourceStatus]

    public static let empty = Dashboard(inProgress: 0, openEscalations: [], projects: [], agents: [], resources: [])

    public var heldCount: Int { resources.reduce(0) { $0 + $1.held.count } }

    public var workingCount: Int { projects.filter { $0.activity == .working }.count }

    /// Projects come from the store and from any project a registered agent names.
    public static func make(snapshot: Snapshot, now: Date = .now) -> Dashboard {
        var projects: [String: Project] = [:]
        for p in snapshot.projects { projects[p.id] = p }
        for a in snapshot.agents where a.isOnTheFloor {
            if let pid = a.projectID, projects[pid] == nil { projects[pid] = Project(path: pid, added: a.registered) }
        }
        let onFloor = snapshot.agents.filter(\.isOnTheFloor).sorted { $0.lastSeen > $1.lastSeen }
        let open = snapshot.escalations.filter(\.isOpen)

        let onHold = Set(projects.values.filter(\.onHold).map(\.id))
        let statuses = projects.values.map { project -> ProjectStatus in
            let agents = onFloor.filter { $0.projectID == project.id }
            // A project on hold shows its name and nothing else: no activity, no counts, no
            // current task. Its open questions still count, since a question still needs
            // an answer. (Alex, 12 Sep 2026: hide info about projects on hold.)
            let questions = open.filter { $0.projectID == project.id }.count
            if project.onHold {
                return ProjectStatus(
                    project: project, activity: .idle, currentTask: nil, agents: agents, openEscalations: questions,
                    backlogCount: 0, blockedCount: 0, inProgressCount: 0, doneCount: 0)
            }
            let activity: ProjectActivity =
                agents.contains { $0.isWorking(now: now) } ? .working : (agents.isEmpty ? .idle : .waiting)
            let tasks = snapshot.tasks.filter { $0.projectID == project.id }
            return ProjectStatus(
                project: project,
                activity: activity,
                currentTask: Backlog.current(for: project.id, in: snapshot.tasks),
                agents: agents,
                openEscalations: questions,
                backlogCount: tasks.filter { $0.state == .backlog }.count,
                blockedCount: tasks.filter { $0.state == .blocked }.count,
                inProgressCount: tasks.filter { $0.state == .inProgress }.count,
                doneCount: tasks.filter { $0.state == .done }.count
            )
        }
        .sorted { a, b in
            // On hold sorts last, then by activity, then by name.
            if a.project.onHold != b.project.onHold { return !a.project.onHold }
            if a.activity != b.activity { return rank(a.activity) < rank(b.activity) }
            return a.project.name.localizedCaseInsensitiveCompare(b.project.name) == .orderedAscending
        }

        let agentStatuses = onFloor.map { agent in
            AgentStatus(
                agent: agent,
                project: agent.projectID.flatMap { projects[$0] },
                task: agent.taskID.flatMap { id in snapshot.tasks.first { $0.id == id } },
                isWorking: agent.isWorking(now: now),
                waitingOnYou: open.contains { $0.agentID == agent.id })
        }

        let names = Dictionary(uniqueKeysWithValues: snapshot.agents.map { ($0.id, $0.name) })
        let resources = snapshot.resources.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map { r in
            ResourceStatus(resource: r, held: Leases.held(for: r.id, in: snapshot.leases, agents: snapshot.agents, now: now).map {
                Holding(lease: $0, agentName: names[$0.agentID] ?? "someone", isOverdue: $0.until <= now)
            })
        }

        return Dashboard(
            inProgress: snapshot.tasks.filter { $0.state == .inProgress && !onHold.contains($0.projectID) }.count,
            openEscalations: open.sorted { $0.raised < $1.raised },
            projects: statuses,
            agents: agentStatuses,
            resources: resources
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
