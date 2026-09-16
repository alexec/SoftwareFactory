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

    /// What an agent is doing, as one word and one colour. Four, because there are four
    /// things worth telling apart on a floor: it is working, it wants you, it has
    /// finished, or it is not there. (T423, Alex, 15 Sep 2026.)
    ///
    /// It used to be five and two of them were guesses. `working` meant "said something
    /// to the factory in the last ten minutes", which is a proxy for a turn in flight and
    /// a poor one: an agent polling the backlog looked busy and an agent thinking hard
    /// about one file looked idle. `idle` and `waiting` were the same state told apart by
    /// whether it held a task. The daemon knows which agents have a turn in flight, so
    /// the guess is gone for every agent it holds.
    public enum AgentActivity: String, Sendable {
        /// A turn in flight. The daemon's own answer for an ACP agent; for a terminal or
        /// external one, still the ten-minute proxy, because there is nobody to ask.
        case working
        /// It wants you: a question open, a permission waiting, or its task blocked on a
        /// person. The one state that is about you rather than about it.
        case askingYou
        /// Nothing in flight and nothing wanted. Finished, or between turns.
        case finished
        /// Its process has gone, or it has been put away. The one state silence could
        /// never tell you: a crashed agent and a thinking one both say nothing, and this
        /// asks the kernel instead of waiting an hour to assume. Only for an agent that
        /// told us its process. (Alex, 13 Sep 2026; archived agents joined it in T415.)
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


        /// Stop is there only for an agent whose process the factory knows and which is
        /// still running. Everything else has nothing to stop. (T261.)
        public var canStop: Bool { Agents.mayStop(agent) }

        /// The other half of Stop: an agent the factory watched stop can be started back
        /// up, in the conversation it was already having. (T262.)
        public var canResume: Bool { Agents.mayResume(agent) }
        /// Why there is no Start on this one, when it has stopped and cannot come back.
        public var whyNoResume: String? { Agents.whyNoResume(agent) }
    }

    /// The one rule behind an agent's dot.
    ///
    /// Order matters and is the argument. Gone beats everything, whatever the agent last
    /// said. Then what it wants from you, because that is the only one you can act on.
    /// Then whether it is mid-turn: `Agent.isPrompting` is the daemon's answer, written
    /// onto the record so the phone reads the same dot as the Mac, and it is only a guess
    /// for an agent nobody holds. (T423 and T425.)
    public static func activity(
        of agent: Agent, task: FactoryTask?, hasOpenQuestion: Bool, now: Date
    ) -> AgentActivity {
        if agent.isArchived || agent.hasExited { return .stopped }
        // A question of its own, or a task it cannot move until you say something. A
        // block on another task or on a decision is not yours to clear, so it is not this.
        if hasOpenQuestion { return .askingYou }
        if task?.state == .blocked, task?.blockers.contains(where: { $0.kind == .person }) == true {
            return .askingYou
        }
        // The daemon holds ACP agents and says which have a turn in flight. For a terminal
        // or external agent there is nobody to ask, so a call in the last ten minutes is
        // still the best available answer.
        if agent.runtime == .acp { return agent.isPrompting ? .working : .finished }
        return agent.isWorking(now: now) ? .working : .finished
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
    /// Put away: the agents that are stopped and hidden. Not on the floor, not in any
    /// count, and drawn in one place so there is a way to take one back out. (T415.)
    public var archived: [Agent] = []
    public var resources: [ResourceStatus]

    public static let empty = Dashboard(inProgress: 0, openEscalations: [], projects: [], agents: [], resources: [])

    public var heldCount: Int { resources.reduce(0) { $0 + $1.held.count } }

    public var workingCount: Int { projects.filter { $0.activity == .working }.count }

    /// The floor in two groups: the ones with a process still running, and the ones
    /// whose process has gone. A stopped agent stays on the list, because it can be
    /// started back up in the conversation it was having; it simply stops sitting
    /// among the agents that are working. Order inside each group is the order they
    /// registered, the same as `agents`. (T268.)
    public var runningAgents: [AgentStatus] { agents.filter { $0.activity != .stopped } }

    public var stoppedAgents: [AgentStatus] { agents.filter { $0.activity == .stopped } }

    /// The agents on one project, working ones first and stopped ones after, each group
    /// in the order they registered.
    ///
    /// The sidebar hangs these under the project rather than listing every agent in a
    /// section of its own. An agent belongs to the work it is doing: with eight on the
    /// floor, one flat list means reading every row's project name to find the two on
    /// the thing you care about. Stopped ones come after rather than being left out,
    /// because a stopped agent is not gone, it is waiting to be started back up (T268).
    /// Pass nil for the agents on no project, which hang under that row the same way.
    /// (T359, Alex, 15 Sep 2026.)
    public func agents(on projectID: String?) -> [AgentStatus] {
        let mine = agents.filter { $0.project?.id == projectID }
        return mine.filter { $0.activity != .stopped } + mine.filter { $0.activity == .stopped }
    }

    /// Agents on no project: the sidebar's No project row. (T176, 13 Sep 2026.)
    ///
    /// Nothing makes one any more. Every launch names a project since T411, so this is the
    /// agents started before that rule, and the row and the page are drawn only while it
    /// is not empty. It stays because they are still working, not because the state is
    /// still reachable.
    public var unassignedAgents: [AgentStatus] { agents.filter { $0.project == nil } }

    public var unassignedIsEmpty: Bool { unassignedAgents.isEmpty }

    public var unassignedActivity: AgentActivity {
        Self.busiest(unassignedAgents.map(\.activity))
    }

    /// One dot for a group of agents: what the loudest of them is doing. Wanting you
    /// beats working, because it is the one you can act on. (T423.)
    public static func busiest(_ doing: [AgentActivity], whenNone: AgentActivity = .stopped) -> AgentActivity {
        if doing.contains(.askingYou) { return .askingYou }
        if doing.contains(.working) { return .working }
        if doing.contains(.finished) { return .finished }
        return whenNone
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
        // Archived agents are off this list, which is what puts them off the sidebar, the
        // floor count and the status board in one move. They are still in the store and
        // `archived` below is where they are seen from. (T415.)
        let byNumber: (Agent, Agent) -> Bool = {
            ($0.number ?? .max, $0.label) < ($1.number ?? .max, $1.label)
        }
        let registered = snapshot.agents.filter { $0.isRegistered && !$0.isArchived }.sorted(by: byNumber)
        let putAway = snapshot.agents.filter { $0.isRegistered && $0.isArchived }.sorted(by: byNumber)
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
                    project: project, activity: .finished, agents: agents, openEscalations: questions,
                    backlogCount: 0, blockedCount: 0, inProgressCount: 0, doneCount: 0)
            }
            // One rule for both dots: whatever its agents are doing, the project is. The
            // busiest of them wins, so a project with one working agent reads working.
            let doing = agents.map { agent -> AgentActivity in
                let task = agent.taskID.flatMap { id in snapshot.tasks.first { $0.id == id } }
                return Dashboard.activity(of: agent, task: task,
                                          hasOpenQuestion: open.contains { $0.agentID == agent.id }, now: now)
            }
            // A stopped agent does not make its project stopped: the project has finished,
            // which is what it has until somebody picks it back up.
            let activity: ProjectActivity = Self.busiest(doing.filter { $0 != .stopped },
                                                         whenNone: .finished)
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
            // Three bands, and the order is the order you look in: projects somebody is
            // on, then projects nobody is on, then the ones set aside. Inside a band, the
            // busiest first and then by name. An empty project used to sort by an activity
            // it did not have, so one nobody was on could sit above one being worked on.
            // (T437, Alex, 15 Sep 2026.)
            if a.project.onHold != b.project.onHold { return !a.project.onHold }
            let manned = { (p: ProjectStatus) in p.agents.contains { !$0.hasExited } }
            if manned(a) != manned(b) { return manned(a) }
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
            archived: putAway,
            resources: resources
        )
    }

    /// The order projects sit in: working first, then what is stuck, then what waits,
    /// then what is quiet.
    private static func rank(_ a: ProjectActivity) -> Int {
        switch a {
        case .working: 0
        case .askingYou: 1
        case .finished: 2
        case .stopped: 3
        }
    }
}
