import Foundation

/// The shape of every record on disk and in iCloud. Bump when a record changes in a way
/// an older reader could not cope with; a reader always decodes an older shape.
public enum Records {
    public static let version = 1
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
    public var added: Date
    /// Set aside by the person: nothing is handed out from its backlog and agents are
    /// told so. Everything stays; the switch is in the app only.
    public var onHold = false
    /// Set when the project was taken out of the factory. The record stays on disk and
    /// out of every list, with its tasks. (Director, 12 Sep 2026: a wrong path.)
    public var removed: Date?
    /// Words from the person for whoever works on this project next. Each is handed to
    /// an agent on its next call about the project and then gone. (Alex, 12 Sep 2026:
    /// a way to steer the agent.)
    public var notes: [Note] = []
    /// Notes already handed over, so a copy that comes back from another device is not
    /// handed over twice. The last fifty.
    public var sentNoteIDs: [UUID] = []

    public struct Note: Codable, Identifiable, Hashable, Sendable {
        public var id: UUID
        public var text: String
        public var by: String
        public var at: Date

        public init(id: UUID = UUID(), text: String, by: String, at: Date = .now) {
            self.id = id
            self.text = text
            self.by = by
            self.at = at
        }
    }

    public init(name: String, id: String = UUID().uuidString, added: Date = .now) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
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
        added = try c.decode(Date.self, forKey: .added)
        onHold = try c.decodeIfPresent(Bool.self, forKey: .onHold) ?? false
        removed = try c.decodeIfPresent(Date.self, forKey: .removed)
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        sentNoteIDs = try c.decodeIfPresent([UUID].self, forKey: .sentNoteIDs) ?? []
    }

}

/// One task on a project's backlog: a feature, a bug or a chore. Called `FactoryTask` in
/// Swift only because `Task` is taken by concurrency; it is a task everywhere a person reads it.
public struct FactoryTask: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case feature, bug, chore
        /// A UX review, a luxury audit, an App Store compliance pass: work that produces
        /// findings rather than a change. (Alex, 12 September 2026.)
        case review
        /// Closing-out work on the store record: the listing, privacy and support pages,
        /// the build attached, the repo made private. (Director, 12 Sep 2026: most of the
        /// fleet's closing work is this, not review.)
        case ship
    }

    public enum State: String, Codable, CaseIterable, Sendable {
        case backlog, inProgress, done
        /// Seen by the person and set aside: not next, not done, not forgotten.
        case parked
        /// Waiting on something named in `blocker`. Not next; an agent moves on.
        case blocked
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
    public var kind: Kind
    public var state: State
    /// Position on the backlog. Lower comes first.
    public var rank: Int
    public var note: String
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
        case version, id, number, projectID, title, kind, state, rank, note, agentID, blockers, removed, created, updated
        case legacyBlocker = "blocker"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(number, forKey: .number)
        try c.encode(projectID, forKey: .projectID)
        try c.encode(title, forKey: .title)
        try c.encode(kind, forKey: .kind)
        try c.encode(state, forKey: .state)
        try c.encode(rank, forKey: .rank)
        try c.encode(note, forKey: .note)
        try c.encodeIfPresent(agentID, forKey: .agentID)
        if !blockers.isEmpty { try c.encode(blockers, forKey: .blockers) }
        try c.encodeIfPresent(removed, forKey: .removed)
        try c.encode(created, forKey: .created)
        try c.encode(updated, forKey: .updated)
    }

    public init(
        id: UUID = UUID(), number: Int? = nil, projectID: String, title: String, kind: Kind = .feature,
        state: State = .backlog, rank: Int, note: String = "", agentID: UUID? = nil,
        created: Date = .now
    ) {
        self.id = id
        self.number = number
        self.projectID = projectID
        self.title = title
        self.kind = kind
        self.state = state
        self.rank = rank
        self.note = note
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
        kind = try c.decode(Kind.self, forKey: .kind)
        state = try c.decode(State.self, forKey: .state)
        rank = try c.decode(Int.self, forKey: .rank)
        note = try c.decode(String.self, forKey: .note)
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
    public var name: String
    public var projectID: String?
    public var taskID: UUID?
    public var note: String
    public var registered: Date
    public var lastSeen: Date
    public var deregistered: Date?
    /// What the agent runs on. Only "claude-code" today. (Alex, 12 Sep 2026.)
    public var provider: String?
    /// A link to the agent's own session, so the person can open it and look under
    /// the hood: a claude:// link for Claude Code.
    public var url: String?
    /// Set when the person nudged the agent; handed over on its next call and cleared.
    public var nudged: Date?
    /// Task ids already offered to this agent by the Stop hook, so a task is announced
    /// only once. Last 50 kept.
    public var announcedTasks: [UUID] = []

    public static let providers = ["claude-code"]

    public var hasIntroducedItself: Bool {
        !(provider ?? "").isEmpty && !(url ?? "").isEmpty
    }

    public init(id: UUID = UUID(), name: String, projectID: String?, registered: Date = .now) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.note = ""
        self.registered = registered
        self.lastSeen = registered
    }

    public var isOnTheFloor: Bool { deregistered == nil }

    /// An agent is seen whenever it touches the factory: claims, updates, questions,
    /// leases. Ten minutes without any of that and it reads as quiet. (Alex, 12 Sep 2026:
    /// no separate check-in; infer it from the task updates.)
    public static let quietAfter: TimeInterval = 10 * 60
    /// An hour of silence and an agent that never said goodbye is marked gone anyway.
    public static let goneAfter: TimeInterval = 60 * 60

    public func isWorking(now: Date) -> Bool {
        isOnTheFloor && now.timeIntervalSince(lastSeen) <= Self.quietAfter
    }

    /// Still registered, but silent for an hour.
    public func hasGoneQuiet(now: Date) -> Bool {
        isOnTheFloor && now.timeIntervalSince(lastSeen) > Self.goneAfter
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        taskID = try c.decodeIfPresent(UUID.self, forKey: .taskID)
        note = try c.decode(String.self, forKey: .note)
        registered = try c.decode(Date.self, forKey: .registered)
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        deregistered = try c.decodeIfPresent(Date.self, forKey: .deregistered)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        nudged = try c.decodeIfPresent(Date.self, forKey: .nudged)
        announcedTasks = try c.decodeIfPresent([UUID].self, forKey: .announcedTasks) ?? []
    }

}

/// The sweep the factory runs on every look: agents that stopped checking in are marked
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
            agent.note = agent.note.isEmpty ? "marked gone after an hour of silence" : agent.note + " · marked gone after an hour of silence"
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
