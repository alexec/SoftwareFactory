import Foundation

/// What one agent actually does, as opposed to what the protocol says it may do.
///
/// ACP tells you the shape of a message and almost nothing about the behaviour behind it.
/// All four of ours are conformant and all four disagree: a prompt arriving mid-turn is
/// queued by one, dropped by another and taken in place of the turn in flight by a third,
/// and the specification has no opinion. A capability flag does not help either, because
/// Cursor declares `loadSession` and then refuses `session/load`.
///
/// So the factory keeps its own notes. Each one says what was measured, what was not, and
/// when, and the app reads them rather than guessing: an agent that cannot be started back
/// up is not offered a Start. Measured by driving each agent through the daemon, not by
/// reading its documentation, which is how the disagreements were found in the first
/// place. (T373, 16 Sep 2026.)
public struct AgentProfile: Sendable, Equatable {
    public var agent: LaunchAgent
    /// Whether a stopped one can be picked back up, and how well.
    public var resuming: Resuming
    /// What it does with a prompt that arrives while it is working. The factory never
    /// sends one, so this is a note rather than a rule: it is why the rule exists.
    public var whenBusy: WhenBusy
    /// Whether it asks before it changes something.
    public var asksFirst: Known
    /// Whether it says what it is thinking, which the page can fold away.
    public var thinksOutLoud: Known
    /// Whether it sets out a plan that ticks itself off.
    public var plans: Known
    /// Whether it puts a question to the person through the protocol, `elicitation/create`,
    /// rather than asking in prose and ending the turn. Only Claude Code does. The others
    /// write "Alpha or Beta? 1. Alpha 2. Beta" as a message and stop, which is a question
    /// the floor cannot see, so `escalation_raise` is how they ask and always will be.
    public var asksThroughTheProtocol: Known
    /// Whether its tool calls say what kind of thing they are. Grok's carry a title and
    /// no `kind`, so its rows fall back to the title and `ToolCall.Kind.changesAnything`
    /// never gets to speak for it.
    public var namesToolKinds: Known
    /// Anything the person should know before they pick it. Empty when there is nothing.
    public var caveat: String?

    public init(agent: LaunchAgent, resuming: Resuming, whenBusy: WhenBusy,
                asksFirst: Known, thinksOutLoud: Known, plans: Known,
                namesToolKinds: Known = .untested, asksThroughTheProtocol: Known = .untested,
                caveat: String? = nil) {
        self.agent = agent
        self.resuming = resuming
        self.whenBusy = whenBusy
        self.asksFirst = asksFirst
        self.thinksOutLoud = thinksOutLoud
        self.plans = plans
        self.namesToolKinds = namesToolKinds
        self.asksThroughTheProtocol = asksThroughTheProtocol
        self.caveat = caveat
    }

    /// Three answers, not two. "We have not tried it" is a different thing from "no", and
    /// writing it down as no would quietly take a feature away from an agent that has it.
    public enum Known: String, Sendable, Equatable {
        case yes, no, untested

        public var word: String {
            switch self {
            case .yes: "Yes"
            case .no: "No"
            case .untested: "Not tried"
            }
        }
    }

    public enum Resuming: String, Sendable, Equatable {
        /// `session/load` works and it comes back knowing what it was doing.
        case theConversation
        /// It loads, but replays rather than picking up where it left off.
        case byReplaying
        /// It will not load. Start is not offered, and says why.
        case no
        /// Not tried yet, so Start is offered and may fail honestly.
        case untested

        public var canStart: Bool { self != .no }

        public var word: String {
            switch self {
            case .theConversation: "Yes, in the same conversation"
            case .byReplaying: "Yes, by replaying it"
            case .no: "No"
            case .untested: "Not tried"
            }
        }
    }

    /// What it does with a prompt sent while a turn is in flight. Measured on all four,
    /// and the reason `AgentFloor` never sends one: two of these lose something, and
    /// neither leaves a trace.
    public enum WhenBusy: String, Sendable, Equatable {
        /// Queues it and answers both. Claude Code, which advertises `promptQueueing`.
        case queues
        /// Drops it. The turn in flight finishes, the new words never happen, no error.
        case dropsIt
        /// Cancels what it was doing and takes the new words instead.
        case cancelsItsWork
        case untested

        public var word: String {
            switch self {
            case .queues: "Queues it"
            case .dropsIt: "Drops it silently"
            case .cancelsItsWork: "Cancels what it is doing"
            case .untested: "Not tried"
            }
        }

        /// Whether sending one mid-turn would lose something. Nothing depends on this,
        /// because the factory waits for every agent, but it is why.
        public var losesSomething: Bool { self == .dropsIt || self == .cancelsItsWork }
    }
}

public extension LaunchAgent {
    /// What this one was measured doing. See `AgentProfile`.
    var profile: AgentProfile {
        switch self {
        case .claudeCode:
            AgentProfile(agent: self, resuming: .theConversation, whenBusy: .queues,
                         asksFirst: .yes, thinksOutLoud: .yes, plans: .untested,
                         namesToolKinds: .yes, asksThroughTheProtocol: .yes)
        case .copilot:
            AgentProfile(agent: self, resuming: .theConversation, whenBusy: .dropsIt,
                         asksFirst: .yes, thinksOutLoud: .yes, plans: .untested,
                         namesToolKinds: .yes, asksThroughTheProtocol: .no)
        case .grok:
            AgentProfile(agent: self, resuming: .theConversation, whenBusy: .queues,
                         asksFirst: .no, thinksOutLoud: .yes, plans: .untested,
                         namesToolKinds: .no, asksThroughTheProtocol: .no,
                         caveat: "It does not ask before it changes something, so nothing it does will ever reach you as a question. Its tool calls carry a name but not what kind of thing they are, so its rows say what it called the tool.")
        case .cursor:
            AgentProfile(agent: self, resuming: .no, whenBusy: .cancelsItsWork,
                         asksFirst: .untested, thinksOutLoud: .untested, plans: .untested,
                         namesToolKinds: .untested, asksThroughTheProtocol: .untested,
                         caveat: "It says it can load a session and then refuses one, so a stopped Cursor agent cannot be started back up. The account also needs a plan before it will do any work here.")
        case .terminal:
            AgentProfile(agent: self, resuming: .untested, whenBusy: .untested,
                         asksFirst: .no, thinksOutLoud: .no, plans: .no,
                         namesToolKinds: .no, asksThroughTheProtocol: .no,
                         caveat: "Not an agent. A shell, which speaks none of this.")
        }
    }
}
