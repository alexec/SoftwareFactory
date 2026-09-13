import Foundation

/// The shape of every record on disk and in iCloud. Bump when a record changes in a way
/// an older reader could not cope with; a reader always decodes an older shape.
public enum Records {
    /// 2: a task no longer carries a kind. A reader from version 1 wanted one and would
    /// skip the record, so the number goes up. (Alex, 12 Sep 2026: we never used it.)
    /// 3: an agent no longer carries a name. It was always its label and nothing ever
    /// set it to anything else. A reader from version 2 wanted one and would skip the
    /// record. (T158, 13 Sep 2026.)
    /// Work (design, plan, implement, fix, review, investigate, ship) is a new optional
    /// field on a task, default implement. An older record without it reads as implement;
    /// the old `kind` of feature/bug/chore is still ignored. No bump: an older reader
    /// skips a key it does not know. (T166, 13 Sep 2026.)
    public static let version = 3
}

/// A product being built, identified by its folder. The path is the id because it is the
/// one thing the Mac app, the iPhone app and every agent agree on. A project is a name,
/// nothing more: an app, a cross-cutting role, a piece of tooling. It has no folder.
/// (Alex, 12 Sep 2026: paths removed; the director's Research had no single folder.)
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var version = Records.version
    /// Stable and opaque. Projects from before 12 Sep 2026 carry their old folder path here.
    public var id: String
    public var name: String
    /// A short explanation of when an agent should use this project.
    public var description: String
    /// Project-specific guidance shown once to each agent before it works its backlog.
    public var instructions: String
    public var added: Date
    /// Set aside by the person: nothing is handed out from its backlog and agents are
    /// told so. Everything stays; the switch is in the app only.
    public var onHold = false
    /// Set when the project was taken out of the factory. The record stays on disk and
    /// out of every list, with its tasks. (Director, 12 Sep 2026: a wrong path.)
    public var removed: Date?
    /// Where an agent runs for this project: a folder on this Mac, set by hand from the
    /// project page or by project_set_path. Nothing to do with the id above, and nothing
    /// requires it; a project with no single folder just leaves it unset.
    public var path: String?

    public init(name: String, description: String = "", instructions: String = "", id: String = UUID().uuidString, added: Date = .now) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        self.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        self.added = added
    }

    /// What an old caller meant by a folder path: the folder's name. "/Users/a/Where/" is "Where".
    public static func name(fromPath path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return URL(fileURLWithPath: p).lastPathComponent
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        added = try c.decode(Date.self, forKey: .added)
        onHold = try c.decodeIfPresent(Bool.self, forKey: .onHold) ?? false
        removed = try c.decodeIfPresent(Date.self, forKey: .removed)
        path = try c.decodeIfPresent(String.self, forKey: .path)
    }

}

/// One task on a project's backlog. Called `FactoryTask` in Swift only because `Task` is
/// taken by concurrency; it is a task everywhere a person reads it.
public struct FactoryTask: Codable, Identifiable, Hashable, Sendable {
    public enum State: String, Codable, CaseIterable, Sendable {
        case backlog, inProgress, done
        /// Seen by the person and set aside: not next, not done, not forgotten.
        case parked
        /// Waiting on something named in `blocker`. Not next; an agent moves on.
        case blocked
    }

    /// What the agent is being asked to do. Named `work` so it never collides with the
    /// old `kind` (feature, bug, chore) that may still sit on a version-1 record.
    public enum Work: String, Codable, CaseIterable, Sendable {
        /// Produce a design brief, then stop for a look.
        case design
        /// Plan the implementation, then stop for approval.
        case plan
        /// Do the work. The default.
        case implement
        /// Find the cause and fix it.
        case fix
        /// Look at the result. Fix what the review says to fix; log the rest.
        case review
        /// Find out. Don't change anything.
        case investigate
        /// Put a build in someone's hands: the device, testers, or the store.
        case ship

        /// The word on the picker and the row.
        public var word: String {
            switch self {
            case .design: "Design"
            case .plan: "Plan"
            case .implement: "Implement"
            case .fix: "Fix"
            case .review: "Review"
            case .investigate: "Investigate"
            case .ship: "Ship"
            }
        }

        /// One line for an agent, a tooltip, the full task view.
        public var brief: String {
            switch self {
            case .design: "Produce a design brief for review, then stop. Don't implement."
            case .plan: "Plan the implementation for review and approval, then stop. Don't implement."
            case .implement: "Do the work."
            case .fix: "Find the cause and fix it."
            case .review: "Look at the result. Fix what the review says to fix; log the rest."
            case .investigate: "Find out. Don't change anything."
            case .ship: "Put a build in someone's hands: the device, testers, or the store."
            }
        }

        /// Fits after "Claim it, read its note." in the launch words.
        public var instruction: String {
            switch self {
            case .implement: "Do it, and say when it is done."
            default: "\(brief) Say when it is done."
            }
        }
    }

    /// What a blocked task waits on. A decision or a task clears on its own; a person or
    /// anything else clears when someone says so.
    public struct Blocker: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case decision, task, person, other
        }

        public var kind: Kind
        public var id: UUID?
        public var why: String

        public init(kind: Kind, id: UUID? = nil, why: String) {
            self.kind = kind
            self.id = id
            self.why = why
        }
    }

    public var version = Records.version
    public var id: UUID
    /// A short number people can say and type, T509, unique across every project. New
    /// tasks take the next one; a task can be given one to match numbers already in use
    /// elsewhere. (Director, 12 Sep 2026.) Nil on tasks from before numbers existed.
    public var number: Int?
    public var projectID: String
    public var title: String
    public var state: State
    /// Position on the backlog. Lower comes first.
    public var rank: Int
    public var note: String
    /// What the agent should produce. Not the old feature/bug/chore kind, which came out
    /// because nothing read it: this one is read. Default implement, which is what every
    /// task was before the field existed. (T166, 13 Sep 2026.)
    public var work: Work
    /// The agent on it, when one is.
    public var agentID: UUID?
    /// Everything the task waits on while the state is `blocked`. It clears when the
    /// last one does; one on a person or "other" clears only by hand.
    public var blockers: [Blocker] = []
    /// Set when the task was taken off the backlog. Nothing is ever deleted; a removed
    /// task is kept out of every list and stays in the store with the reason.
    public var removed: Date?
    public var created: Date
    public var updated: Date

    /// The first blocker, for a one-line view.
    public var blocker: Blocker? { blockers.first }
    /// Every reason, as one line.
    public var blockedWhy: String { blockers.map(\.why).joined(separator: "; ") }

    /// "T509", or nil.
    public var label: String? { number.map { "T\($0)" } }

    enum CodingKeys: String, CodingKey {
        case version, id, number, projectID, title, state, rank, note, work, agentID, blockers, removed, created, updated
        case legacyBlocker = "blocker"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(number, forKey: .number)
        try c.encode(projectID, forKey: .projectID)
        try c.encode(title, forKey: .title)
        try c.encode(state, forKey: .state)
        try c.encode(rank, forKey: .rank)
        try c.encode(note, forKey: .note)
        try c.encode(work, forKey: .work)
        try c.encodeIfPresent(agentID, forKey: .agentID)
        if !blockers.isEmpty { try c.encode(blockers, forKey: .blockers) }
        try c.encodeIfPresent(removed, forKey: .removed)
        try c.encode(created, forKey: .created)
        try c.encode(updated, forKey: .updated)
    }

    public init(
        id: UUID = UUID(), number: Int? = nil, projectID: String, title: String,
        state: State = .backlog, rank: Int, note: String = "", work: Work = .implement,
        agentID: UUID? = nil, created: Date = .now
    ) {
        self.id = id
        self.number = number
        self.projectID = projectID
        self.title = title
        self.state = state
        self.rank = rank
        self.note = note
        self.work = work
        self.agentID = agentID
        self.created = created
        self.updated = created
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        projectID = try c.decode(String.self, forKey: .projectID)
        title = try c.decode(String.self, forKey: .title)
        state = try c.decode(State.self, forKey: .state)
        rank = try c.decode(Int.self, forKey: .rank)
        note = try c.decode(String.self, forKey: .note)
        work = try c.decodeIfPresent(Work.self, forKey: .work) ?? .implement
        agentID = try c.decodeIfPresent(UUID.self, forKey: .agentID)
        // Version 1 wrote one `blocker`; it reads as a list of one.
        blockers = try c.decodeIfPresent([Blocker].self, forKey: .blockers)
            ?? (try c.decodeIfPresent(Blocker.self, forKey: .legacyBlocker)).map { [$0] } ?? []
        removed = try c.decodeIfPresent(Date.self, forKey: .removed)
        created = try c.decode(Date.self, forKey: .created)
        updated = try c.decode(Date.self, forKey: .updated)
    }

}

/// A worker that has registered with the factory. What it runs on is its own business.
public struct Agent: Codable, Identifiable, Hashable, Sendable {
    public var version = Records.version
    public var id: UUID
    /// The short public identifier used by MCP callers. The UUID remains the stable
    /// storage and relationship key.
    public var number: Int?
    public var about: String
    public var projectID: String?
    /// The latest instructions read for each project, keyed by the stable project id.
    /// Keeping the text makes a changed instruction visible again.
    public var seenInstructions: [String: String]
    public var taskID: UUID?
    public var note: String
    /// The terminal session this agent runs in, when the app started it: the name it
    /// passes at registration from SOFTWARE_FACTORY_SESSION. The app attaches to it to
    /// show the agent working. Nil for an agent started by hand.
    ///
    /// Do not use this to decide whether the agent is running. It lives on the launch
    /// wrapper and nowhere else, so an agent that has been resumed has lost it while
    /// still working perfectly well. `pid` is the question about running.
    public var session: String?
    /// The agent's own process, reported at registration, and when that process started.
    /// The pair is what makes an answer about running trustworthy: a pid on its own can
    /// be recycled and turn up wearing a dead agent's number, and a start time settles
    /// which process is really there. The factory fills in the start time itself, so an
    /// agent only has to know its own pid. Nil for an agent that did not say.
    /// (Alex, 13 Sep 2026.)
    public var pid: Int32?
    public var pidStartedAt: Date?
    public var registered: Date
    public var lastSeen: Date
    /// The quiet and gone timers start only after the MCP session disconnects.
    public var isConnected: Bool
    public var deregistered: Date?

    public init(id: UUID = UUID(), number: Int? = nil, about: String = "", projectID: String?, registered: Date = .now) {
        self.id = id
        self.number = number
        self.about = about
        self.projectID = projectID
        self.seenInstructions = [:]
        self.note = ""
        self.registered = registered
        self.lastSeen = registered
        self.isConnected = false
    }

    public var isRegistered: Bool { deregistered == nil }

    /// What an agent is called, everywhere: its agent_id, the name on its card, the name
    /// in a sentence. Its number, or its raw id for one that registered before numbers.
    /// There is no second name: an agent used to carry one and it was only ever this,
    /// which made the next reader think the two could differ. (T158, 13 Sep 2026.)
    public var label: String {
        number.map { "A\($0)" } ?? id.uuidString
    }

    /// Once disconnected, an agent reads as quiet after ten minutes without a call.
    public static let quietAfter: TimeInterval = 10 * 60
    /// An hour after disconnect, an agent that never said goodbye is marked gone.
    public static let goneAfter: TimeInterval = 60 * 60

    /// Whether this agent's process is alive. Only an answer when the agent told us its
    /// pid and the process is on this machine; `knowsItsProcess` says whether to ask.
    public var isProcessRunning: Bool {
        ProcessCheck.isRunning(pid: pid, startedAt: pidStartedAt)
    }

    /// Whether the factory can speak for this agent's process at all. An agent that
    /// never reported a pid is not dead, it is simply not something we can see.
    public var knowsItsProcess: Bool { pid != nil && pidStartedAt != nil }

    /// Whether the factory started this agent, or it joined from outside.
    ///
    /// Two kinds of agent, and they have different lives. An embedded one was written
    /// down before it launched, told the name to register as, and put in a terminal the
    /// factory owns: its page shows it working, you can type to it, and the factory can
    /// stop it. An external one registered over MCP from wherever it already was. It is
    /// just as real and does the same work; there is simply nothing here to watch and
    /// nothing here to stop. (Alex, 13 Sep 2026.)
    ///
    /// This is the agent's origin, not whether there is a terminal on screen right now.
    /// An embedded agent whose tmux session has been killed is still ours; it is only
    /// out of sight. Ask the app whether it holds a terminal for it, and ask this what
    /// kind of agent it is.
    public var isEmbedded: Bool { session != nil }

    /// Registered, said it was running here, and its process has gone. The one state the
    /// factory used to have no way of telling from a quiet agent.
    public var hasExited: Bool { isRegistered && knowsItsProcess && !isProcessRunning }

    public func isWorking(now: Date) -> Bool {
        isRegistered && (isConnected || now.timeIntervalSince(lastSeen) <= Self.quietAfter)
    }

    /// Whether a session is live on this agent right now, for the questions only one
    /// answer can win: who holds this name, who is in this terminal. The flag on its own
    /// is not enough, because a session that died with the app never says goodbye, so ten
    /// minutes of silence gives it up. (Alex, 13 Sep 2026.)
    public func hasLiveSession(now: Date) -> Bool {
        isRegistered && isConnected && now.timeIntervalSince(lastSeen) <= Self.quietAfter
    }

    /// Still registered, and silent for an hour. The connection flag does not save it:
    /// a session that died with the app never says goodbye, and every call is a
    /// heartbeat, so an hour without one means gone. A waiting tool answers long before
    /// that, so an agent parked in escalation_await keeps itself alive.
    /// (Alex, 12 Sep 2026.)
    public func hasGoneQuiet(now: Date) -> Bool {
        isRegistered && now.timeIntervalSince(lastSeen) > Self.goneAfter
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        // A record written before T158 carries a name. It is read and thrown away: it
        // was always the label, and an agent from before numbers falls back to its id.
        about = try c.decodeIfPresent(String.self, forKey: .about) ?? ""
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        seenInstructions = try c.decodeIfPresent([String: String].self, forKey: .seenInstructions) ?? [:]
        taskID = try c.decodeIfPresent(UUID.self, forKey: .taskID)
        note = try c.decode(String.self, forKey: .note)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        // Added after the fact, so a record written before this simply has no pid and
        // reads as an agent whose running we cannot speak for. No version bump needed.
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        pidStartedAt = try c.decodeIfPresent(Date.self, forKey: .pidStartedAt)
        registered = try c.decode(Date.self, forKey: .registered)
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        isConnected = try c.decodeIfPresent(Bool.self, forKey: .isConnected) ?? false
        deregistered = try c.decodeIfPresent(Date.self, forKey: .deregistered)
    }

}

/// Who works here. The number is the name: A1, A2, A3.
public enum Agents {
    /// The next free number, one more than the highest ever used. Numbers are never
    /// given out twice, so an agent that has left keeps its name in the record.
    public static func nextNumber(in agents: [Agent]) -> Int {
        (agents.compactMap(\.number).max() ?? 0) + 1
    }

    /// An agent the app is about to start: it has its name before it registers, so the
    /// person sees the card the moment they click, and the terminal belongs to it from
    /// the start. The agent then registers with this same id, passing it as `agent_id`.
    /// (Alex, 13 Sep 2026: the prompt tells the agent who it is.)
    ///
    /// The number comes from the factory's counter on disk, not from the agents still in
    /// the store, so a number is never handed out twice.
    public static func reserve(number: Int, projectID: String?, session: String?, now: Date = .now) -> Agent {
        var agent = Agent(number: number, projectID: projectID, registered: now)
        agent.session = session
        return agent
    }

    /// What happens when an agent registers saying it is in a terminal session. One
    /// terminal holds one agent: two on the same session means two cards, one window,
    /// and whatever you type reaching the wrong one. (Alex, 13 Sep 2026: I have seen it.)
    ///
    /// A shell that outlives its agent keeps SOFTWARE_FACTORY_SESSION exported, so the
    /// next agent started by hand in that window reports the same session. The session
    /// goes to whoever is actually in the window: the newcomer, and it comes off the
    /// record that held it. An agent still live in there keeps it, and the newcomer gets
    /// no session rather than a window that is not its own.
    public struct SessionClaim: Sendable, Equatable {
        /// The session the newcomer keeps. Nil when someone else is still in there.
        public var session: String?
        /// Records to save with their session cleared.
        public var released: [Agent]
    }

    public static func claimSession(
        _ session: String, for newcomer: Agent, in agents: [Agent], now: Date
    ) -> SessionClaim {
        let holders = agents.filter { $0.session == session && $0.id != newcomer.id && $0.isRegistered }
        if holders.contains(where: { $0.hasLiveSession(now: now) }) {
            return SessionClaim(session: nil, released: [])
        }
        return SessionClaim(session: session, released: holders.map {
            var released = $0
            released.session = nil
            return released
        })
    }
}

/// One message in an agent's private inbox.
public struct AgentMessage: Codable, Identifiable, Hashable, Sendable {
    public var version = Records.version
    public var id: UUID
    public var recipientID: UUID
    public var from: String
    public var subject: String
    public var contents: String
    public var sent: Date

    public init(id: UUID = UUID(), recipientID: UUID, from: String, subject: String, contents: String, sent: Date = .now) {
        self.id = id
        self.recipientID = recipientID
        self.from = from
        self.subject = subject
        self.contents = contents
        self.sent = sent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        recipientID = try c.decode(UUID.self, forKey: .recipientID)
        from = try c.decode(String.self, forKey: .from)
        subject = try c.decode(String.self, forKey: .subject)
        contents = try c.decode(String.self, forKey: .contents)
        sent = try c.decode(Date.self, forKey: .sent)
    }
}

/// The sweep the factory runs on every look: agents disconnected for an hour are marked
/// gone and their leases released, so a crashed session never holds a phone all day.
public enum Sweep {
    public struct Changes: Equatable, Sendable {
        public var agents: [Agent]
        public var leases: [Lease]

        public var isEmpty: Bool { agents.isEmpty && leases.isEmpty }
    }

    /// Blocked tasks whose blocker has cleared: the decision was made, or the task is
    /// done. They go back to the backlog with a line saying so.
    public static func unblocked(in snapshot: Snapshot, now: Date) -> [FactoryTask] {
        snapshot.tasks.compactMap { task in
            guard task.state == .blocked, !task.blockers.isEmpty else { return nil }
            var remaining: [FactoryTask.Blocker] = []
            var cleared: [String] = []
            for (index, b) in task.blockers.enumerated() {
                switch b.kind {
                case .decision:
                    if let id = b.id, let e = snapshot.escalations.first(where: { $0.id == id }), let answer = e.answer {
                        cleared.append("decided \(e.question) → \(answer), by \(e.decision?.by ?? "someone")")
                        // A wait on a person written before this question was the same
                        // gate: the answer clears it too. Rows blocked before task_block
                        // learnt to replace it still carry both.
                        let asked = remaining.filter { $0.kind == .person && task.blockers.firstIndex(of: $0)! < index }
                        if !asked.isEmpty {
                            remaining.removeAll { asked.contains($0) }
                            cleared.append("and with it the wait on \(asked.map(\.why).joined(separator: "; "))")
                        }
                    } else { remaining.append(b) }
                case .task:
                    if let id = b.id, let t = snapshot.tasks.first(where: { $0.id == id }), t.state == .done {
                        cleared.append("\(t.title) is done")
                    } else { remaining.append(b) }
                case .person, .other:
                    remaining.append(b)
                }
            }
            guard !cleared.isEmpty else { return nil }
            let line = (remaining.isEmpty ? "unblocked, " : "cleared, ") + cleared.joined(separator: "; ")
            var t = task
            if remaining.isEmpty {
                t = Backlog.set(task, to: .backlog, at: now)
            } else {
                t.blockers = remaining
                t.updated = now
            }
            t.note = t.note.isEmpty ? line : t.note + "\n" + line
            return t
        }
    }

    public static func goneAgents(in snapshot: Snapshot, now: Date) -> Changes {
        var changes = Changes(agents: [], leases: [])
        for var agent in snapshot.agents where agent.hasGoneQuiet(now: now) {
            agent.deregistered = now
            agent.note = agent.note.isEmpty ? "marked gone after an hour disconnected" : agent.note + " · marked gone after an hour disconnected"
            changes.agents.append(agent)
            for var lease in Leases.heldBy(agent.id, in: snapshot.leases, now: now) {
                lease.released = now
                changes.leases.append(lease)
            }
        }
        return changes
    }
}

/// A question an agent cannot answer itself. It offers options and marks the one it
/// recommends; the person's choice is recorded here as the decision.
public struct Escalation: Codable, Identifiable, Hashable, Sendable {
    public struct Option: Codable, Identifiable, Hashable, Sendable {
        public var id: UUID
        public var title: String
        public var detail: String
        public var recommended: Bool

        public init(id: UUID = UUID(), title: String, detail: String = "", recommended: Bool = false) {
            self.id = id
            self.title = title
            self.detail = detail
            self.recommended = recommended
        }
    }

    /// The person's answer: one of the options, with a note for the agent if they
    /// added one, or their own words instead of any option. (Alex, 12 Sep 2026.)
    public struct Decision: Codable, Hashable, Sendable {
        /// Nil when the answer is in the person's own words.
        public var optionID: UUID?
        /// A note to go with the option, or the whole answer when there is no option.
        public var note: String
        public var by: String
        public var at: Date

        public init(optionID: UUID?, note: String = "", by: String, at: Date) {
            self.optionID = optionID
            self.note = note
            self.by = by
            self.at = at
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            optionID = try c.decodeIfPresent(UUID.self, forKey: .optionID)
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            by = try c.decode(String.self, forKey: .by)
            at = try c.decode(Date.self, forKey: .at)
        }
    }

    public var version = Records.version
    public var id: UUID
    public var projectID: String
    public var question: String
    public var context: String
    public var options: [Option]
    public var agentID: UUID?
    /// The task this question stops, when it came from one.
    public var taskID: UUID?
    public var raisedBy: String
    public var raised: Date
    public var decision: Decision?

    public init(
        id: UUID = UUID(), projectID: String, question: String, context: String = "",
        options: [Option], agentID: UUID? = nil, taskID: UUID? = nil, raisedBy: String = "agent", raised: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.question = question
        self.context = context
        self.options = options
        self.agentID = agentID
        self.taskID = taskID
        self.raisedBy = raisedBy
        self.raised = raised
    }

    public var isOpen: Bool { decision == nil }

    public var recommended: Option? { options.first { $0.recommended } }

    public var chosen: Option? {
        guard let decision, let id = decision.optionID else { return nil }
        return options.first { $0.id == id }
    }

    /// True when the person answered in their own words rather than with an option.
    public var answeredInOwnWords: Bool { decision != nil && decision?.optionID == nil }

    /// The answer as one line for the agent: the option's title, with the note after
    /// it, or the person's own words.
    public var answer: String? {
        guard let decision else { return nil }
        if let chosen {
            return decision.note.isEmpty ? chosen.title : "\(chosen.title). \(decision.note)"
        }
        return decision.note
    }

    /// Records the choice, with a note for the agent if there is one. Choosing again
    /// replaces the earlier choice.
    public mutating func decide(_ option: Option, note: String = "", by: String = "alex", at date: Date = .now) throws(EscalationError) {
        guard options.contains(where: { $0.id == option.id }) else { throw .unknownOption }
        decision = Decision(optionID: option.id, note: note.trimmingCharacters(in: .whitespacesAndNewlines), by: by, at: date)
    }

    /// Records an answer in the person's own words, none of the options.
    public mutating func answer(_ text: String, by: String = "alex", at date: Date = .now) throws(EscalationError) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .emptyAnswer }
        decision = Decision(optionID: nil, note: text, by: by, at: date)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        projectID = try c.decode(String.self, forKey: .projectID)
        question = try c.decode(String.self, forKey: .question)
        context = try c.decode(String.self, forKey: .context)
        options = try c.decode([Option].self, forKey: .options)
        agentID = try c.decodeIfPresent(UUID.self, forKey: .agentID)
        taskID = try c.decodeIfPresent(UUID.self, forKey: .taskID)
        raisedBy = try c.decode(String.self, forKey: .raisedBy)
        raised = try c.decode(Date.self, forKey: .raised)
        decision = try c.decodeIfPresent(Decision.self, forKey: .decision)
    }

}

public enum EscalationError: Error, Equatable, Sendable {
    case unknownOption
    case emptyAnswer
}

/// Something only so many agents can use at once: a phone, a browser, the Mac itself,
/// or a budget of compiles. Each has a number of slots and a longest lease.
public struct Resource: Codable, Identifiable, Hashable, Sendable {
    public var version = Records.version
    public var id: UUID
    public var name: String
    public var slots: Int
    /// The longest a single lease may run, in seconds. A renewal starts the clock again.
    public var maxLease: TimeInterval
    public var note: String
    public var created: Date

    public init(id: UUID = UUID(), name: String, slots: Int = 1, maxLease: TimeInterval = 3600, note: String = "", created: Date = .now) {
        self.id = id
        self.name = name
        self.slots = max(1, slots)
        self.maxLease = max(60, maxLease)
        self.note = note
        self.created = created
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        slots = try c.decode(Int.self, forKey: .slots)
        maxLease = try c.decode(TimeInterval.self, forKey: .maxLease)
        note = try c.decode(String.self, forKey: .note)
        created = try c.decode(Date.self, forKey: .created)
    }

}

/// One slot of a resource, held by one agent, until a time. It expires on its own, so a
/// dead agent never holds a phone all day.
public struct Lease: Codable, Identifiable, Hashable, Sendable {
    public var version = Records.version
    public var id: UUID
    public var resourceID: UUID
    public var agentID: UUID
    public var why: String
    public var since: Date
    public var until: Date
    public var released: Date?

    public init(id: UUID = UUID(), resourceID: UUID, agentID: UUID, why: String, since: Date, until: Date) {
        self.id = id
        self.resourceID = resourceID
        self.agentID = agentID
        self.why = why
        self.since = since
        self.until = until
    }

    public func isActive(now: Date) -> Bool {
        released == nil && until > now
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        resourceID = try c.decode(UUID.self, forKey: .resourceID)
        agentID = try c.decode(UUID.self, forKey: .agentID)
        why = try c.decode(String.self, forKey: .why)
        since = try c.decode(Date.self, forKey: .since)
        until = try c.decode(Date.self, forKey: .until)
        released = try c.decodeIfPresent(Date.self, forKey: .released)
    }

}
