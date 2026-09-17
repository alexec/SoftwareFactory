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
        /// Everything in this agent's name, blocked first, which is more than `task`: an
        /// agent holding three has two of them in its name and nowhere else. The sidebar
        /// draws a line for each, and it used to work them out in the view body, once per
        /// row and again for the row's help, which is a pass over every task in the store
        /// per line of the sidebar. `make` already walks that array. (T362, then T526.)
        public var held: [FactoryTask] = []
        /// The one report this agent keeps, if it has filed one. Same argument as `held`:
        /// the row and its help both want it and the view was finding it twice.
        public var report: Artifact?
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

        // Indexed once, read many times. This is the one place that walks every task and
        // every agent, and it used to walk them again for each of twenty-one projects and
        // each of sixteen agents: the project counts filtered all 587 tasks per project,
        // and an agent's current task was found with `first(where:)` twice over, once here
        // and once for its own status. Grouping costs one pass and the questions are then
        // lookups. (R67, T526.)
        let tasksByProject = Dictionary(grouping: snapshot.tasks, by: \.projectID)
        var taskByID: [UUID: FactoryTask] = [:]
        // Everything in an agent's name, gathered in the same pass, in whatever order the
        // store gave them; sorted per agent below, where the lists are short.
        var heldByAgent: [UUID: [FactoryTask]] = [:]
        for task in snapshot.tasks {
            taskByID[task.id] = task
            if let who = task.agentID, task.removed == nil, !task.state.isFinished {
                heldByAgent[who, default: []].append(task)
            }
        }
        let asking = Set(open.compactMap(\.agentID))
        // The one report per agent per project, off the same list `Artifacts.statusReport`
        // reads. Keyed by both, because both is what identifies one: an agent moved from
        // one project to another has a report on each and only the one on the project it
        // is on now is its line in the sidebar.
        struct WhoseReport: Hashable { var agent: UUID; var project: String }
        var reportBy: [WhoseReport: Artifact] = [:]
        for report in snapshot.artifacts
        where report.kind == .statusReport && report.removed == nil {
            guard let who = report.agentID else { continue }
            let key = WhoseReport(agent: who, project: report.projectID)
            // Newest wins, which is the order `statusReports` put them in.
            if let already = reportBy[key], already.updated >= report.updated { continue }
            reportBy[key] = report
        }

        let onHold = Set(projects.values.filter(\.onHold).map(\.id))
        let statuses = projects.values.map { project -> ProjectStatus in
            let agents = registered.filter { $0.projectID == project.id }
            // A project on hold shows its name and nothing else: no activity, no counts, no
            // current task. (Alex, 12 Sep 2026: hide info about projects on hold.) Its open
            // questions used to be the exception, counted even here, and that was for the
            // number on the sidebar row, which came off in T507: a question is answered on
            // the Needs you strip, in the agent's own chat, in a banner, on the phone and on
            // the Lock Screen, and the project row could do nothing about it. The questions
            // themselves are on the dashboard, `Dashboard.openEscalations`, which is what
            // all five of those read.
            if project.onHold {
                return ProjectStatus(
                    project: project, activity: .finished, agents: agents,
                    backlogCount: 0, blockedCount: 0, inProgressCount: 0, doneCount: 0)
            }
            // One rule for both dots: whatever its agents are doing, the project is. The
            // busiest of them wins, so a project with one working agent reads working.
            let doing = agents.map { agent -> AgentActivity in
                Dashboard.activity(of: agent, task: agent.taskID.flatMap { taskByID[$0] },
                                   hasOpenQuestion: asking.contains(agent.id), now: now)
            }
            // A stopped agent does not make its project stopped: the project has finished,
            // which is what it has until somebody picks it back up.
            let activity: ProjectActivity = Self.busiest(doing.filter { $0 != .stopped },
                                                         whenNone: .finished)
            var backlog = 0, blocked = 0, going = 0, done = 0
            for t in tasksByProject[project.id] ?? [] {
                switch t.state {
                case .backlog: backlog += 1
                case .blocked: blocked += 1
                case .inProgress: going += 1
                default: if t.state.isFinished { done += 1 }
                }
            }
            return ProjectStatus(
                project: project,
                activity: activity,
                agents: agents,
                backlogCount: backlog,
                blockedCount: blocked,
                inProgressCount: going,
                doneCount: done
            )
        }
        .sorted { a, b in
            if band(a) != band(b) { return band(a) < band(b) }
            if a.activity != b.activity { return rank(a.activity) < rank(b.activity) }
            return a.project.name.localizedCaseInsensitiveCompare(b.project.name) == .orderedAscending
        }

        let agentStatuses = registered.map { agent in
            let task = agent.taskID.flatMap { taskByID[$0] }
            let question = asking.contains(agent.id)
            return AgentStatus(
                agent: agent,
                project: agent.projectID.flatMap { projects[$0] },
                task: task,
                held: (heldByAgent[agent.id] ?? []).sorted(by: Backlog.order),
                report: agent.projectID.flatMap { reportBy[WhoseReport(agent: agent.id, project: $0)] },
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

    /// Where a project sits in the sidebar, as four bands read top down: somebody is on it,
    /// somebody was on it and has stopped, nobody has ever been on it, it is set aside.
    ///
    /// A project whose agents have all exited used to fall in with the ones nobody has ever
    /// started anything on, because the only question asked was whether somebody was on it.
    /// Those are not the same thing: a project with a stopped agent is work that was going
    /// and is not, which is something to pick back up, and a project with no agents is one
    /// that has not been started. The first is worth seeing sooner. (T437, then T499.)
    ///
    /// **Four, not five** (T513, Alex, 15 Sep 2026: "projects with any alive tasks, projects
    /// with any stopped tasks, projects with no tasks, projects on hold"). There used to be
    /// a band between the first two for a project whose live agents had all finished, and
    /// nothing is lost by merging it: the sort falls through to `rank(activity)` inside a
    /// band, which already puts working above asking above finished, so a project with
    /// somebody working still sits above one whose agent has finished. The band was saying a
    /// second time what the activity rank was already saying, and a rule that repeats
    /// another rule is a rule that can disagree with it.
    ///
    /// Read as agents rather than tasks, because a task is never stopped: a project's tasks
    /// are backlog, in progress, done, parked or blocked. An agent is what stops.
    public static func band(_ p: ProjectStatus) -> Int {
        // On hold is set aside on purpose, so it goes last however busy it was.
        if p.project.onHold { return 3 }
        // Anybody still there, whatever they are doing. The activity rank sorts within.
        if p.agents.contains(where: { !$0.hasExited }) { return 0 }
        return p.agents.isEmpty ? 2 : 1
    }

    private static func rank(_ a: ProjectActivity) -> Int {
        switch a {
        case .working: 0
        case .askingYou: 1
        case .finished: 2
        case .stopped: 3
        }
    }
}
