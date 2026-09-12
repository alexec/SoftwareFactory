import Foundation

/// A product being built, identified by its folder. The path is the id because it is the
/// one thing the Mac app, the iPhone app and every agent agree on.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var added: Date

    public init(path: String, name: String? = nil, added: Date = .now) {
        self.id = Project.canonical(path)
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.added = added
    }

    public var path: String { id }

    public static func canonical(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

/// One task on a project's backlog: a feature, a bug or a chore. Called `FactoryTask` in
/// Swift only because `Task` is taken by concurrency; it is a task everywhere a person reads it.
public struct FactoryTask: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case feature, bug, chore
    }

    public enum State: String, Codable, CaseIterable, Sendable {
        case backlog, inProgress, done
    }

    public var id: UUID
    public var projectID: String
    public var title: String
    public var kind: Kind
    public var state: State
    /// Position on the backlog. Lower comes first.
    public var rank: Int
    public var note: String
    /// The agent on it, when one is.
    public var agentID: UUID?
    public var created: Date
    public var updated: Date

    public init(
        id: UUID = UUID(), projectID: String, title: String, kind: Kind = .feature,
        state: State = .backlog, rank: Int, note: String = "", agentID: UUID? = nil,
        created: Date = .now
    ) {
        self.id = id
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
}

/// A worker that has registered with the factory. What it runs on is its own business.
public struct Agent: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var projectID: String?
    public var taskID: UUID?
    public var note: String
    public var registered: Date
    public var lastSeen: Date
    public var deregistered: Date?

    public init(id: UUID = UUID(), name: String, projectID: String?, registered: Date = .now) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.note = ""
        self.registered = registered
        self.lastSeen = registered
    }

    public var isOnTheFloor: Bool { deregistered == nil }

    /// Two minutes without a check-in and an agent reads as quiet.
    public static let quietAfter: TimeInterval = 120
    /// Three missed check-ins, at five minutes each, and an agent that never said goodbye
    /// is marked gone anyway.
    public static let goneAfter: TimeInterval = 15 * 60

    public func isWorking(now: Date) -> Bool {
        isOnTheFloor && now.timeIntervalSince(lastSeen) <= Self.quietAfter
    }

    /// Still registered, but silent for longer than three check-ins.
    public func hasGoneQuiet(now: Date) -> Bool {
        isOnTheFloor && now.timeIntervalSince(lastSeen) > Self.goneAfter
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

    public static func goneAgents(in snapshot: Snapshot, now: Date) -> Changes {
        var changes = Changes(agents: [], leases: [])
        for var agent in snapshot.agents where agent.hasGoneQuiet(now: now) {
            agent.deregistered = now
            agent.note = agent.note.isEmpty ? "marked gone after three missed check-ins" : agent.note + " · marked gone after three missed check-ins"
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

    public struct Decision: Codable, Hashable, Sendable {
        public var optionID: UUID
        public var by: String
        public var at: Date

        public init(optionID: UUID, by: String, at: Date) {
            self.optionID = optionID
            self.by = by
            self.at = at
        }
    }

    public var id: UUID
    public var projectID: String
    public var question: String
    public var context: String
    public var options: [Option]
    public var agentID: UUID?
    public var raisedBy: String
    public var raised: Date
    public var decision: Decision?

    public init(
        id: UUID = UUID(), projectID: String, question: String, context: String = "",
        options: [Option], agentID: UUID? = nil, raisedBy: String = "agent", raised: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.question = question
        self.context = context
        self.options = options
        self.agentID = agentID
        self.raisedBy = raisedBy
        self.raised = raised
    }

    public var isOpen: Bool { decision == nil }

    public var recommended: Option? { options.first { $0.recommended } }

    public var chosen: Option? {
        guard let decision else { return nil }
        return options.first { $0.id == decision.optionID }
    }

    /// Records the choice. Choosing again replaces the earlier choice.
    public mutating func decide(_ option: Option, by: String = "alex", at date: Date = .now) throws(EscalationError) {
        guard options.contains(where: { $0.id == option.id }) else { throw .unknownOption }
        decision = Decision(optionID: option.id, by: by, at: date)
    }
}

public enum EscalationError: Error, Equatable, Sendable {
    case unknownOption
}

/// Something only so many agents can use at once: a phone, a browser, the Mac itself,
/// or a budget of compiles. Each has a number of slots and a longest lease.
public struct Resource: Codable, Identifiable, Hashable, Sendable {
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
}

/// One slot of a resource, held by one agent, until a time. It expires on its own, so a
/// dead agent never holds a phone all day.
public struct Lease: Codable, Identifiable, Hashable, Sendable {
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
}
