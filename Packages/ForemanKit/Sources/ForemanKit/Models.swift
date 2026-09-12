import Foundation

/// A folder an agent works in. The id is the folder's path, because that is the one
/// thing the Mac app, the iPhone app, the CLI and Claude Code all agree on.
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

/// One item on a project's backlog: a feature, a bug or a chore.
public struct WorkItem: Codable, Identifiable, Hashable, Sendable {
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
    /// Who is on it, when someone is.
    public var agent: String?
    public var created: Date
    public var updated: Date

    public init(
        id: UUID = UUID(), projectID: String, title: String, kind: Kind = .feature,
        state: State = .backlog, rank: Int, note: String = "", agent: String? = nil,
        created: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.kind = kind
        self.state = state
        self.rank = rank
        self.note = note
        self.agent = agent
        self.created = created
        self.updated = created
    }
}

/// A question an agent cannot answer itself. It offers options, marks the one it
/// recommends, and the choice is recorded here when it is made.
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

    public var id: UUID
    public var projectID: String
    public var question: String
    public var context: String
    public var options: [Option]
    public var raisedBy: String
    public var raised: Date
    public var chosenOptionID: UUID?
    public var decided: Date?

    public init(
        id: UUID = UUID(), projectID: String, question: String, context: String = "",
        options: [Option], raisedBy: String = "agent", raised: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.question = question
        self.context = context
        self.options = options
        self.raisedBy = raisedBy
        self.raised = raised
    }

    public var isOpen: Bool { chosenOptionID == nil }

    public var recommended: Option? { options.first { $0.recommended } }

    public var chosen: Option? {
        guard let chosenOptionID else { return nil }
        return options.first { $0.id == chosenOptionID }
    }

    /// Records the choice. Choosing again replaces the earlier choice.
    public mutating func decide(_ option: Option, at date: Date = .now) throws(EscalationError) {
        guard options.contains(where: { $0.id == option.id }) else { throw .unknownOption }
        chosenOptionID = option.id
        decided = date
    }
}

public enum EscalationError: Error, Equatable, Sendable {
    case unknownOption
}

/// A Claude Code session as read from its files on disk.
public struct AgentSession: Identifiable, Hashable, Sendable {
    public enum Activity: String, Sendable {
        /// The transcript changed moments ago: the agent is doing something.
        case working
        /// The process is alive and the transcript is quiet: it is waiting, probably on you.
        case waiting
        /// The process has gone.
        case ended
    }

    public var id: String
    public var cwd: String
    public var name: String?
    public var pid: Int32?
    public var startedAt: Date?
    public var lastActivity: Date
    public var lastPrompt: String?
    public var isLive: Bool

    public init(
        id: String, cwd: String, name: String? = nil, pid: Int32? = nil, startedAt: Date? = nil,
        lastActivity: Date, lastPrompt: String? = nil, isLive: Bool
    ) {
        self.id = id
        self.cwd = Project.canonical(cwd)
        self.name = name
        self.pid = pid
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.lastPrompt = lastPrompt
        self.isLive = isLive
    }

    public var projectID: String { cwd }

    /// Ninety seconds of silence is the line between working and waiting.
    public static let workingWindow: TimeInterval = 90

    public func activity(now: Date) -> Activity {
        guard isLive else { return .ended }
        return now.timeIntervalSince(lastActivity) <= Self.workingWindow ? .working : .waiting
    }

    /// Scratch workspaces the desktop app makes for sessions with no folder.
    public var isScratch: Bool { cwd.contains("/scratch-workspaces/") }
}
