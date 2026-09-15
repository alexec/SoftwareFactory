import Foundation

/// What the app shows, derived from the store.
public struct Dashboard: Sendable, Equatable {
    /// A project reads exactly the way its agents do, so a colour means one thing on the
    /// whole screen. Nobody on it is an absence rather than an activity: it draws no dot.
    /// (Alex, 12 Sep 2026.)
    public typealias ProjectActivity = AgentActivity

    public struct ProjectStatus: Identifiable, Sendable, Equatable {
        public var project: Project
        public var activity: ProjectActivity
        /// Nobody is on it, so it draws no dot at all.
        public var isEmpty: Bool { agents.isEmpty }
        public var agents: [Agent]
        public var openEscalations: Int
        public var backlogCount: Int
        public var blockedCount: Int
        public var inProgressCount: Int
        public var doneCount: Int

        public var id: String { project.id }

        /// One line an agent on it wrote. The current task is on the backlog, not
        /// next to the project's name. Nothing while on hold. (T168, 13 Sep 2026.)
        public var doing: String? {
            if project.onHold { return nil }
            if let note = agents.first?.note, !note.isEmpty { return note }
            return nil
        }
    }

    /// What an agent is doing, as one word and one colour.
    public enum AgentActivity: String, Sendable {
        /// On a task and checked in moments ago.
        case working
        /// Its task is blocked, on a decision, another task, or a person.
        case blocked
        /// Registered with nothing in hand: waiting for a task, for mail, or for
        /// you to answer its question.
        case waiting
        /// Nothing said for ten minutes, and no connection open.
        case idle
        /// Its process has gone. The one state silence could never tell you: a crashed
        /// agent and a thinking one both say nothing, and this asks the kernel instead
        /// of waiting an hour to assume. Only for an agent that told us its process.
        /// (Alex, 13 Sep 2026.)
        case stopped
    }

    public struct AgentStatus: Identifiable, Sendable, Equatable {
        public var agent: Agent
        public var project: Project?
        public var task: FactoryTask?
        public var activity: AgentActivity
        public var waitingOnYou: Bool

        public var id: UUID { agent.id }

        public var isWorking: Bool { activity == .working }

        /// Nudge is there unless the agent has stopped: a working one, a blocked
        /// one, a waiting one and a quiet one can all be poked. A process that has
        /// gone cannot. (T197, 13 Sep 2026.)
        public var canNudge: Bool { activity != .stopped }
    }

    /// The one rule behind an agent's dot. An agent that has gone quiet is idle
    /// whatever it was holding; a blocked task beats waiting, because the block is
    /// the thing to clear.
    public static func activity(
        of agent: Agent, task: FactoryTask?, hasOpenQuestion: Bool, now: Date
    ) -> AgentActivity {
        // Gone beats everything, and beats it whatever the agent last said: an agent
        // whose process has exited is not working, not waiting and not merely quiet.
        if agent.hasExited { return .stopped }
        guard agent.isWorking(now: now) else { return .idle }
        if task?.state == .blocked { return .blocked }
        if hasOpenQuestion || task == nil { return .waiting }
        return .working
    }

    public struct Holding: Identifiable, Sendable, Equatable {
        public var lease: Lease
        public var agentName: String
        /// Past its time, holder still registered.
        public var isOverdue: Bool

        public var id: UUID { lease.id }
    }

    public struct ResourceStatus: Identifiable, Sendable, Equatable {
        public var resource: Resource
        public var held: [Holding]

        public var id: UUID { resource.id }
        public var free: Int { max(0, resource.slots - held.count) }
        /// Slots in use of the total, the same shape as compiles on the Capacity page.
        /// (T184, 13 Sep 2026.)
        public var occupancy: String { "\(held.count) of \(resource.slots)" }
    }

    public var inProgress: Int
    public var openEscalations: [Escalation]
    public var projects: [ProjectStatus]
    public var agents: [AgentStatus]
    public var resources: [ResourceStatus]

    public static let empty = Dashboard(inProgress: 0, openEscalations: [], projects: [], agents: [], resources: [])

    public var heldCount: Int { resources.reduce(0) { $0 + $1.held.count } }

    public var workingCount: Int { projects.filter { $0.activity == .working }.count }

    /// Agents on no project: the sidebar's No project row. (T176, 13 Sep 2026.)
    public var unassignedAgents: [AgentStatus] { agents.filter { $0.project == nil } }

    public var unassignedIsEmpty: Bool { unassignedAgents.isEmpty }

    public var unassignedActivity: AgentActivity {
        let doing = unassignedAgents.map(\.activity)
        if doing.contains(.working) { return .working }
        if doing.contains(.blocked) { return .blocked }
        if doing.contains(.waiting) { return .waiting }
        return .idle
    }

    /// Projects come from the store and from any project a registered agent names.
    public static func make(snapshot: Snapshot, now: Date = .now) -> Dashboard {
        var projects: [String: Project] = [:]
        for p in snapshot.projects { projects[p.id] = p }
        for a in snapshot.agents where a.isRegistered {
            if let pid = a.projectID, projects[pid] == nil { projects[pid] = Project(name: Project.name(fromPath: pid), id: pid, added: a.registered) }
        }
        // In the order they registered, A1 first. Sorting by who spoke last made the
        // cards swap places every couple of seconds. (Alex, 12 Sep 2026.)
        let registered = snapshot.agents.filter(\.isRegistered).sorted {
            ($0.number ?? .max, $0.label) < ($1.number ?? .max, $1.label)
        }
        let open = snapshot.escalations.filter(\.isOpen)

        let onHold = Set(projects.values.filter(\.onHold).map(\.id))
        let statuses = projects.values.map { project -> ProjectStatus in
            let agents = registered.filter { $0.projectID == project.id }
            // A project on hold shows its name and nothing else: no activity, no counts, no
            // current task. Its open questions still count, since a question still needs
            // an answer. (Alex, 12 Sep 2026: hide info about projects on hold.)
            let questions = open.filter { $0.projectID == project.id }.count
            if project.onHold {
                return ProjectStatus(
                    project: project, activity: .idle, agents: agents, openEscalations: questions,
                    backlogCount: 0, blockedCount: 0, inProgressCount: 0, doneCount: 0)
            }
            // One rule for both dots: whatever its agents are doing, the project is. The
            // busiest of them wins, so a project with one working agent reads working.
            let doing = agents.map { agent -> AgentActivity in
                let task = agent.taskID.flatMap { id in snapshot.tasks.first { $0.id == id } }
                return Dashboard.activity(of: agent, task: task,
                                          hasOpenQuestion: open.contains { $0.agentID == agent.id }, now: now)
            }
            // A stopped agent does not make its project stopped: the project is idle,
            // which is what it is until somebody picks it back up.
            let activity: ProjectActivity =
                doing.contains(.working) ? .working
                : doing.contains(.blocked) ? .blocked
                : doing.contains(.waiting) ? .waiting
                : .idle
            let tasks = snapshot.tasks.filter { $0.projectID == project.id }
            return ProjectStatus(
                project: project,
                activity: activity,
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

        let agentStatuses = registered.map { agent in
            let task = agent.taskID.flatMap { id in snapshot.tasks.first { $0.id == id } }
            let question = open.contains { $0.agentID == agent.id }
            return AgentStatus(
                agent: agent,
                project: agent.projectID.flatMap { projects[$0] },
                task: task,
                activity: activity(of: agent, task: task, hasOpenQuestion: question, now: now),
                waitingOnYou: question)
        }

        // Who holds a resource reads as the agent's name, the same name the cards show.
        let names = Dictionary(uniqueKeysWithValues: snapshot.agents.map { ($0.id, $0.label) })
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

    /// The order projects sit in: working first, then what is stuck, then what waits,
    /// then what is quiet.
    private static func rank(_ a: ProjectActivity) -> Int {
        switch a {
        case .working: 0
        case .blocked: 1
        case .waiting: 2
        case .idle: 3
        // A project never reads stopped, only an agent does; it sorts with the quiet.
        case .stopped: 3
        }
    }
}
