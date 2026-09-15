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
    /// An escalation may carry a `link` (http or https) to a document to review. An
    /// older record without it reads as empty; an older reader skips a key it does not
    /// know. No bump. (T174, 13 Sep 2026.)
    /// An escalation may point at an `artifactID` on the project. Filing a `link` on
    /// a question also files that URL as an artifact. An older record without the key
    /// reads as none. No bump.
    /// A project no longer carries a description or instructions; an agent no longer
    /// records seenInstructions. A reader from version 3 wanted those keys on a project
    /// it wrote itself (decodeIfPresent), so an older reader still copes. No bump.
    /// (T167, 13 Sep 2026.)
    /// An agent no longer carries `about`. The terminal title is the line on the card,
    /// and `bel` is how it asks to be looked at. An older record with `about` still
    /// reads; the field is thrown away. An older reader skips `title` and `bel`. No bump.
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

        /// The word on the row and at the start of a title. Implement is "Code"
        /// (T181): that is what you type, and what the row used to call Implement.
        public var word: String {
            switch self {
            case .design: "Design"
            case .plan: "Plan"
            case .implement: "Code"
            case .fix: "Fix"
            case .review: "Review"
            case .investigate: "Investigate"
            case .ship: "Ship"
            }
        }

        /// The first word of a title, if it names a kind of work. "Code" and the
        /// older "Implement" both mean implement. Anything else is nil.
        public static func named(_ token: String) -> Work? {
            let t = token.trimmingCharacters(in: .punctuationCharacters)
            guard !t.isEmpty else { return nil }
            if t.compare("code", options: .caseInsensitive) == .orderedSame { return .implement }
            if t.compare("implement", options: .caseInsensitive) == .orderedSame { return .implement }
            return allCases.first { $0.word.compare(t, options: .caseInsensitive) == .orderedSame }
        }

        /// MCP and HTTP: the stored raw value, the word, or "code".
        public static func parse(_ raw: String) -> Work? {
            if let work = Work(rawValue: raw) { return work }
            return named(raw)
        }

        /// Work from the first token of a title, defaulting to implement when there
        /// is none. The title is kept as typed, prefix and all.
        public static func reading(title: String) -> (work: Work, title: String) {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = title.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            return (named(token) ?? .implement, title)
        }

        /// Work words whose spelling starts with `prefix`, excluding an exact match.
        /// Empty prefix is none: the field is not a picker.
        public static func completions(prefix: String) -> [Work] {
            let p = prefix.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { return [] }
            return allCases.filter {
                $0.word.lowercased().hasPrefix(p.lowercased())
                    && $0.word.lowercased() != p.lowercased()
            }
        }

        /// True when `title` already begins with this word, so the row should not
        /// print it again.
        public func isPrefix(of title: String) -> Bool {
            Self.named(title.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "") == self
        }

        /// One line for an agent, a tooltip, the full task view.
        public var brief: String {
            switch self {
            case .design: "Produce a design brief, put it on the project with artifact_add, then stop. Don't implement."
            case .plan: "Plan the implementation, put the plan on the project with artifact_add, then stop. Don't implement."
            case .implement: "Do the work."
            case .fix: "Find the cause and fix it."
            case .review: "Look at the result. Fix what the review says to fix; log the rest."
            case .investigate: "Find out. Put what you found on the project with artifact_add. Don't change anything."
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
        /// The agent's session, and everything else about who it is. The factory makes this
    /// before it launches anything and hands it to the agent in the words it starts
    /// with, so one UUID is the record's key, the name of the terminal it runs in, the
    /// `--session-id` its CLI was started with, and what it says on every call it makes.
    ///
    /// It is told in the prompt rather than the environment on purpose. An environment
    /// variable is lost the moment a conversation is resumed; the prompt is part of the
    /// conversation, so a resumed agent still knows who it is.
    ///
    /// One consequence worth keeping: two agents can no longer share a terminal, because
    /// the terminal is named after the agent. There is nothing left to claim.
    /// (Alex, 13 Sep 2026.)
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
    /// What the agent's terminal last called itself, via OSC 0/2. Empty until it sets one.
    /// Shown on the card in place of the old self-description.
    public var title: String
    /// The agent rang BEL: it wants a look. The card shows a bell until it is opened.
    public var bel: Bool
    public var projectID: String?
    public var taskID: UUID?
    public var note: String
    /// The factory should start this agent. `agent_create` sets it; the app launches
    /// and clears it. (T179, 13 Sep 2026.)
    public var wantsLaunch: Bool = false
    /// Which CLI the factory started it with, as a `LaunchAgent` raw value. Kept so a
    /// stopped agent can be picked back up in the one that holds its conversation: a
    /// session id made by Claude Code means nothing to Grok. Nil for an agent that
    /// registered from somewhere else, and for every agent started before this was
    /// written down. (T262.)
    public var launchedWith: String?
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
    /// When the factory last asked this agent for a status report. Kept so it is asked
    /// once an hour rather than once every two seconds: the message is deleted the moment
    /// it is typed in, so the mailbox cannot answer "have we already asked". (T262.)
    public var statusAskedAt: Date?
    /// The quiet and gone timers start only after the MCP session disconnects.
    public var isConnected: Bool
    public var deregistered: Date?

    public init(id: UUID = UUID(), number: Int? = nil, title: String = "", projectID: String?, registered: Date = .now) {
        self.id = id
        self.number = number
        self.title = title
        self.bel = false
        self.projectID = projectID
        self.note = ""
        self.registered = registered
        self.lastSeen = registered
        self.isConnected = false
    }

    /// Longest terminal title we keep. The card truncates anyway; this stops a dump
    /// sitting in the record.
    public static let maxTitle = 200

    public static func preparedTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxTitle { return trimmed }
        return String(trimmed.prefix(maxTitle))
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

    enum CodingKeys: String, CodingKey {
        case version, id, number, title, bel, projectID, taskID, note, wantsLaunch
        case launchedWith
        case pid, pidStartedAt, registered, lastSeen, statusAskedAt, isConnected, deregistered
        case about, name
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(number, forKey: .number)
        try c.encode(title, forKey: .title)
        try c.encode(bel, forKey: .bel)
        try c.encodeIfPresent(projectID, forKey: .projectID)
        try c.encodeIfPresent(taskID, forKey: .taskID)
        try c.encode(note, forKey: .note)
        try c.encode(wantsLaunch, forKey: .wantsLaunch)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encodeIfPresent(pidStartedAt, forKey: .pidStartedAt)
        try c.encodeIfPresent(launchedWith, forKey: .launchedWith)
        try c.encode(registered, forKey: .registered)
        try c.encode(lastSeen, forKey: .lastSeen)
        try c.encodeIfPresent(statusAskedAt, forKey: .statusAskedAt)
        try c.encode(isConnected, forKey: .isConnected)
        try c.encodeIfPresent(deregistered, forKey: .deregistered)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        bel = try c.decodeIfPresent(Bool.self, forKey: .bel) ?? false
        // `name` was the label (T158). `about` was a self-description that duplicated
        // the terminal title. Both are read and thrown away.
        _ = try c.decodeIfPresent(String.self, forKey: .name)
        _ = try c.decodeIfPresent(String.self, forKey: .about)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        taskID = try c.decodeIfPresent(UUID.self, forKey: .taskID)
        note = try c.decode(String.self, forKey: .note)
        wantsLaunch = try c.decodeIfPresent(Bool.self, forKey: .wantsLaunch) ?? false
        // `wantsNudge` was the flag that told the app to type a nudge. A nudge is now a
        // message like any other and the message's own `delivered` says whether it has
        // been typed, so the flag is read and thrown away. (Alex, 14 Sep 2026.)
        // Added after the fact, so a record written before this simply has no pid and
        // reads as an agent whose running we cannot speak for. No version bump needed.
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        pidStartedAt = try c.decodeIfPresent(Date.self, forKey: .pidStartedAt)
        launchedWith = try c.decodeIfPresent(String.self, forKey: .launchedWith)
        registered = try c.decode(Date.self, forKey: .registered)
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        // Missing on any record written before status reports existed, which reads as
        // never asked, which is true. No version bump needed.
        statusAskedAt = try c.decodeIfPresent(Date.self, forKey: .statusAskedAt)
        isConnected = try c.decodeIfPresent(Bool.self, forKey: .isConnected) ?? false
        deregistered = try c.decodeIfPresent(Date.self, forKey: .deregistered)
    }

}

/// Who works here. The number is the name: A1, A2, A3.
public enum Agents {
    /// How many may be on the floor at once when the person has not said otherwise.
    /// A hard cap, not a throttle: the one over is refused, from the app and from
    /// `agent_create` alike. (T179, 13 Sep 2026.)
    public static let defaultCap = 8
    /// What the person may set it to. One agent is a floor of one; sixteen is more than
    /// this Mac will thank you for. (T209.)
    public static let capRange = 1...16

    /// Agents are slots the person hands out, the same as a phone or a simulator: the
    /// number of them lives in the throttle, and this is how everything reads it. (T209.)
    public static func cap(_ throttle: Throttle = .default) -> Int {
        min(max(throttle.agentSlots, capRange.lowerBound), capRange.upperBound)
    }

    public static func fullMessage(cap: Int = defaultCap) -> String {
        "The cap is \(cap) \(cap == 1 ? "agent" : "agents") on the floor."
    }

    /// Registered, and not known to have exited. These count toward the cap.
    public static func onTheFloor(_ agents: [Agent]) -> [Agent] {
        agents.filter { $0.isRegistered && !$0.hasExited }
    }

    public static func atCap(_ agents: [Agent], cap: Int = defaultCap) -> Bool {
        onTheFloor(agents).count >= cap
    }

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
    public static func reserve(number: Int, projectID: String?, now: Date = .now) -> Agent {
        Agent(number: number, projectID: projectID, registered: now)
    }

    /// Whether the factory can stop this one. Stopping is ending the process the
    /// factory started, so it can only be offered for a process the factory knows: the
    /// pid it read off the pane when it launched it, with the time that process started
    /// beside it. An agent that registered from somewhere else never told us a process,
    /// and one whose process has already gone has nothing left to stop.
    ///
    /// This is deliberately the same question as `knowsItsProcess`, not "did we launch
    /// it in a terminal we own". A terminal can be lost while the agent works on, and an
    /// agent resumed after a restart is still the process we wrote down. (T261.)
    public static func mayStop(_ agent: Agent) -> Bool {
        agent.isRegistered && agent.knowsItsProcess && !agent.hasExited
    }

    /// Starting one back up. Only an agent the factory launched and then watched stop:
    /// its process is one we wrote down, and the kernel says that process has gone. An
    /// agent that never reported a pid is never called stopped, so it is never offered a
    /// start either, and one still running is asked to stop first. Its conversation is
    /// waiting under its session id, which is why the id had to be given at launch.
    /// (T262.)
    public static func mayResume(_ agent: Agent) -> Bool {
        agent.isRegistered && agent.knowsItsProcess && agent.hasExited
    }

    /// There used to be a rule here for two agents turning up on one terminal: a shell
    /// that outlived its agent kept SOFTWARE_FACTORY_SESSION exported, so the next agent
    /// started in that window reported the same session, and the factory had to decide
    /// who kept the window. The terminal is named after the agent now, so two of them
    /// cannot land on one, and there is nothing to decide. (T156, settled by T-session.)

}

/// One agent's mail, and how much of it may be waiting at once.
///
/// A message lives only until it has been typed into its agent's terminal, and then it is
/// thrown away: the terminal is where it was going, and a copy of what has already
/// arrived is not an inbox, it is a pile. What is left here is what has not landed yet,
/// and three of those is the cap. An agent with three waiting is an agent nobody is
/// reaching, and a fourth message would not change that. (Alex, 14 Sep 2026.)
public enum Mailbox {
    public static let cap = 3

    /// Sent and not yet typed in. A message from before terminal delivery counts as
    /// delivered, so old mail never fills a mailbox.
    public static func waiting(_ messages: [AgentMessage]) -> [AgentMessage] {
        messages.filter { $0.delivered == nil }
    }

    public static func isFull(_ messages: [AgentMessage]) -> Bool {
        waiting(messages).count >= cap
    }

    public static func fullMessage(_ label: String) -> String {
        "Mailbox full: \(label) has \(cap) messages waiting to be typed into their terminal. Send this once those have gone in."
    }
}

/// One message to an agent. It is typed into that agent's terminal, the same way a nudge
/// is, and `delivered` is when that happened. There is no inbox to read any more: an agent
/// that had to ask for its messages only heard between tasks, if it remembered to look,
/// which is not what a message is for. (Alex, 14 Sep 2026.)
public struct AgentMessage: Codable, Identifiable, Hashable, Sendable {
    public var version = Records.version
    public var id: UUID
    public var recipientID: UUID
    public var from: String
    public var subject: String
    public var contents: String
    public var sent: Date
    /// When the app typed it into the recipient's terminal. Nil until then, which is what
    /// the app looks for. A message to an agent with no terminal on screen waits here
    /// rather than being thrown away, and goes in when one appears.
    public var delivered: Date?

    public init(id: UUID = UUID(), recipientID: UUID, from: String, subject: String, contents: String,
                sent: Date = .now, delivered: Date? = nil) {
        self.id = id
        self.recipientID = recipientID
        self.from = from
        self.subject = subject
        self.contents = contents
        self.sent = sent
        self.delivered = delivered
    }

    /// A nudge is a message whose words are the nudge line, so one delivery path carries
    /// both and there is no second mechanism to keep in step.
    public var isNudge: Bool { contents == LaunchPrompt.nudge }

    /// What the app types in. A nudge goes in bare, because that is the line agents have
    /// always read and it works. Anything else says who it is from first: an agent cannot
    /// tell a typed line from the person at the keyboard, so an unattributed message reads
    /// as Alex asking for something.
    public var terminalLine: String {
        if isNudge { return contents }
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = subject.isEmpty ? "Message from \(from)" : "Message from \(from), \(subject)"
        return "\(head): \(contents)"
    }

    enum CodingKeys: String, CodingKey {
        case version, id, recipientID, from, subject, contents, sent, delivered
    }

    /// `delivered` is always written, null included. Left out when nil it would be
    /// indistinguishable from a message written before the field existed, and every new
    /// message would read back as already typed.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encode(recipientID, forKey: .recipientID)
        try c.encode(from, forKey: .from)
        try c.encode(subject, forKey: .subject)
        try c.encode(contents, forKey: .contents)
        try c.encode(sent, forKey: .sent)
        try c.encode(delivered, forKey: .delivered)
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
        // No key at all means a message written before terminal delivery existed, which was
        // read out of an inbox that is gone: count it delivered rather than replaying old
        // mail into a working agent's terminal. An explicit null means it is still waiting.
        delivered = c.contains(.delivered)
            ? try c.decodeIfPresent(Date.self, forKey: .delivered)
            : sent
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
    /// An agent whose process has gone, still holding something. Nobody says goodbye any
    /// more: an agent that crashed could not, and one that exited cleanly has no reason
    /// to, so the kernel is asked instead. Whatever it was holding goes back.
    ///
    /// This replaces an hour of silence and a deregistration. Silence was always a guess
    /// (an agent thinking is silent too) and a goodbye was always optional. A process
    /// that is not there is neither. (T-session, 13 Sep 2026.)
    public static func stoppedAgents(in snapshot: Snapshot, now: Date) -> Changes {
        var changes = Changes(agents: [], leases: [])
        for agent in snapshot.agents where agent.hasExited {
            for var lease in Leases.heldBy(agent.id, in: snapshot.leases, now: now) {
                lease.released = now
                changes.leases.append(lease)
            }
        }
        return changes
    }

    /// Agents to stop because the project they are on has just gone on hold.
    ///
    /// On hold used to mean nothing new is handed out, and the agents already on the
    /// project worked on. That is not what a person means when they put a project on
    /// hold: they mean the work on it stops. So the ones on it are stopped, which is the
    /// same stop as the button, and Start picks each of them back up in the conversation
    /// it was having when the project comes off hold. (T309, Alex, 15 Sep 2026.)
    ///
    /// The transition is what counts, not the state. A project that has been on hold all
    /// along is left alone, so an agent started on a held project on purpose is not
    /// stopped the moment it registers, and a project the factory is seeing for the
    /// first time is no transition at all: at launch every held project would otherwise
    /// look like one that had just been held.
    public static func agentsHeld(before: Snapshot, after: Snapshot) -> [Agent] {
        let known = Set(before.projects.map(\.id))
        let wasHeld = Set(before.projects.filter(\.onHold).map(\.id))
        let justHeld = Set(
            after.projects
                .filter { $0.onHold && known.contains($0.id) && !wasHeld.contains($0.id) }
                .map(\.id))
        guard !justHeld.isEmpty else { return [] }
        return after.agents.filter { agent in
            guard let projectID = agent.projectID, justHeld.contains(projectID) else { return false }
            return Agents.mayStop(agent)
        }
    }

    /// How long an agent sits with nothing to do before the factory stops it.
    public static let idleStandsFor: TimeInterval = 60 * 60

    /// Agents with nothing to do and nothing coming, which the factory stops.
    ///
    /// An agent costs a slot, a terminal and whatever its CLI is holding open, and an
    /// agent that finished an hour ago on a project with an empty backlog is costing all
    /// of that for nothing. Stop is not the end of it: Start picks the conversation back
    /// up where it left off, its pane keeps what it said, and what it held goes back on
    /// its own. That is what makes this safe enough to do without asking. (T357,
    /// Alex, 15 Sep 2026.)
    ///
    /// Nothing to do means all four of these, because each one is a way of being busy
    /// that looks like silence:
    ///
    /// - No task in its name that is in progress or blocked. Blocked counts as busy: it
    ///   is waiting on something, and the factory clears its own blocks.
    /// - No question of its own still open. An agent that raised one and is waiting for
    ///   an answer is doing exactly what it should.
    /// - Nothing on its project's backlog for it to pick up. Work waiting means a poke
    ///   is the right move rather than a stop, which is `agentsToPoke`.
    /// - No mail waiting, because something is about to be said to it.
    ///
    /// An hour is measured from the last of: when it registered, and when a task of its
    /// own last changed. Not from `lastSeen`, which a polling agent keeps fresh while
    /// doing nothing at all.
    ///
    /// An agent on no project is left alone. There is no backlog to be empty, so "no new
    /// tasks" says nothing about it, and it is there because the person started it for
    /// something of their own.
    public static func idleAgentsToStop(
        in snapshot: Snapshot, messages: [AgentMessage], now: Date
    ) -> [Agent] {
        let waitingFor = Set(Mailbox.waiting(messages).map(\.recipientID))
        let asking = Set(snapshot.escalations.filter(\.isOpen).compactMap(\.agentID))
        let projectsWithWork = Set(
            snapshot.tasks.filter { $0.state == .backlog && $0.removed == nil }.map(\.projectID))

        return Agents.onTheFloor(snapshot.agents).filter { agent in
            guard Agents.mayStop(agent) else { return false }
            guard let projectID = agent.projectID else { return false }
            guard !projectsWithWork.contains(projectID) else { return false }
            guard !waitingFor.contains(agent.id), !asking.contains(agent.id) else { return false }

            let mine = snapshot.tasks.filter { $0.agentID == agent.id }
            guard !mine.contains(where: { $0.state == .inProgress || $0.state == .blocked })
            else { return false }

            let since = max(agent.registered, mine.map(\.updated).max() ?? agent.registered)
            return now.timeIntervalSince(since) >= idleStandsFor
        }
    }

    /// The agent to poke because work has landed on a project where nobody is working.
    ///
    /// Filing a task and then going to find an agent to tell about it is a step the
    /// factory can take itself. Only when every agent on that project is idle: if one of
    /// them is on a task, it will read the backlog when it finishes, and poking it now
    /// interrupts the work to tell it about work. The first agent by number gets it,
    /// because somebody has to and the lowest number is the one that has been there
    /// longest.
    ///
    /// The transition is what counts, not the state, so it fires once as the task
    /// arrives however it arrived: the add row, dictation, an agent's task_add, the
    /// phone. A project the factory is seeing for the first time is no transition, or
    /// every backlog would be a nudge at launch. An agent with mail already waiting is
    /// left alone: another line in the queue is not another poke. (T352, Alex, 15 Sep 2026.)
    public static func agentsToPoke(
        before: Snapshot, after: Snapshot, messages: [AgentMessage], now: Date
    ) -> [Agent] {
        guard !before.tasks.isEmpty || !before.projects.isEmpty else { return [] }
        let known = Set(before.tasks.map(\.id))
        let landed = Set(
            after.tasks
                .filter { !known.contains($0.id) && $0.state == .backlog && $0.removed == nil }
                .map(\.projectID))
        guard !landed.isEmpty else { return [] }
        let waitingFor = Set(Mailbox.waiting(messages).map(\.recipientID))
        let working = Set(
            after.tasks.filter { $0.state == .inProgress }.compactMap(\.agentID))

        return landed.compactMap { projectID -> Agent? in
            let onIt = Agents.onTheFloor(after.agents)
                .filter { $0.projectID == projectID }
                .sorted { ($0.number ?? .max, $0.registered) < ($1.number ?? .max, $1.registered) }
            guard !onIt.isEmpty else { return nil }
            guard !onIt.contains(where: { working.contains($0.id) }) else { return nil }
            return onIt.first { !waitingFor.contains($0.id) }
        }
    }

    /// Agents that owe the person a word about how it is going, and the message that
    /// asks each of them for one.
    ///
    /// An agent is quiet for long stretches by design, and silence on the floor reads
    /// the same whether the work is going well or the agent is lost in a rabbit hole.
    /// So the factory asks: once an hour, and only of an agent that has not said
    /// anything in that hour. (T262, Alex, 15 Sep 2026.)
    ///
    /// Three things stop an ask, and they are all the same thing said three ways: a
    /// report filed in the last hour, an ask sent in the last hour, and an agent that
    /// started in the last hour and has not had time to have anything to report. The
    /// newest of those three is what the hour is measured from. A message already
    /// waiting stops it too: asking twice for something nobody has read yet is noise.
    public static func statusReportsWanted(
        in snapshot: Snapshot, messages: [AgentMessage], now: Date
    ) -> (agents: [Agent], messages: [AgentMessage]) {
        var stamped: [Agent] = []
        var asks: [AgentMessage] = []
        let waitingFor = Set(Mailbox.waiting(messages).map(\.recipientID))
        for agent in Agents.onTheFloor(snapshot.agents) {
            guard let projectID = agent.projectID,
                  let project = snapshot.projects.first(where: { $0.id == projectID }),
                  project.removed == nil else { continue }
            guard !waitingFor.contains(agent.id) else { continue }
            var since = agent.registered
            if let asked = agent.statusAskedAt { since = max(since, asked) }
            if let report = Artifacts.statusReport(by: agent.id, on: projectID, in: snapshot.artifacts) {
                since = max(since, report.updated)
            }
            guard now.timeIntervalSince(since) >= Artifacts.statusReportStandsFor else { continue }
            var agent = agent
            agent.statusAskedAt = now
            stamped.append(agent)
            asks.append(AgentMessage(
                recipientID: agent.id, from: "the factory",
                subject: LaunchPrompt.statusReportSubject,
                contents: LaunchPrompt.statusReport(on: project), sent: now))
        }
        return (stamped, asks)
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
    /// Optional URL of a document the person should read before they choose. Empty if none.
    /// Filing one also files an artifact on the project, so the document lives here.
    public var link: String
    /// The document on the project they should read, when there is one.
    public var artifactID: UUID?
    public var options: [Option]
    public var agentID: UUID?
    /// The task this question stops, when it came from one.
    public var taskID: UUID?
    public var raisedBy: String
    public var raised: Date
    public var decision: Decision?

    public init(
        id: UUID = UUID(), projectID: String, question: String, context: String = "",
        link: String = "", artifactID: UUID? = nil, options: [Option], agentID: UUID? = nil, taskID: UUID? = nil,
        raisedBy: String = "agent", raised: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.question = question
        self.context = context
        self.link = link
        self.artifactID = artifactID
        self.options = options
        self.agentID = agentID
        self.taskID = taskID
        self.raisedBy = raisedBy
        self.raised = raised
    }

    /// Empty if none. http or https, with a host; anything else is refused so a bad
    /// string never sits on the card as a dead control.
    public static func validatedLink(_ raw: String?) throws(EscalationError) -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { throw .badLink }
        return text
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
        link = try c.decodeIfPresent(String.self, forKey: .link) ?? ""
        artifactID = try c.decodeIfPresent(UUID.self, forKey: .artifactID)
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
    case badLink
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
