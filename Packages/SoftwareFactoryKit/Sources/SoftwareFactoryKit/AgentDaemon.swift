#if os(macOS)
import Foundation

/// The floor's process holder, and the words the app uses to talk to it.
///
/// An ACP agent is a subprocess of its client and dies with it. The factory's most useful
/// property is the opposite: tmux owned the process, so a dozen rebuilds a day left eight
/// agents working. So the app is not the client. `software-factory agentd` is, it runs
/// outside the app, and the app tells it what to do.
///
/// It is a smaller thing than tmux by a long way, and that is the whole argument for
/// owning it. tmux is a terminal multiplexer: ptys, ANSI, scrollback, resize, copy mode.
/// Under ACP there is a pipe with JSON going along it. The daemon holds the pipe, writes
/// every line to a file, and answers questions about what it is holding.
///
/// **The stream is not on this socket.** Every line an agent sends is appended to
/// `transcripts/<agent>.jsonl` under the store, and the app reads that file the same way
/// it reads every other record in the store. So this wire carries commands and state
/// only, request and reply, no subscriptions: the durable thing was going to be a file
/// either way, and a socket that also streams is a second copy of the truth that can
/// disagree with the first. (T373.)
public enum AgentDaemon {
    /// Where the daemon listens. Not under the store: a unix socket path is capped at
    /// 104 characters and a group container path spends most of that before we start.
    /// This is the folder tmux's own state already lives in.
    public static var socketPath: String {
        stateFolder.appending(path: "agentd.sock").path
    }

    public static var stateFolder: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/state/software-factory", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: What the app asks for

    public struct Request: Codable, Sendable, Equatable {
        public var op: Op
        /// Which agent. The factory's own id, not the one ACP hands back.
        public var agent: UUID?
        /// Which CLI to run, a `LaunchAgent` raw value.
        public var kind: String?
        /// The project's folder. An agent has to stand somewhere.
        public var cwd: String?
        /// The words it starts with, or the words to say to one already running.
        public var text: String?
        /// Answering a permission request or a question: which one, and which option.
        public var requestID: Int?
        public var optionID: String?
        /// Answering a question in the person's own words, when the agent offered a place
        /// for them.
        public var words: String?
        /// Files dropped on the agent, as paths rather than as bytes. The daemon reads
        /// them: it is the side that knows what this agent will take, and a screenshot
        /// down a unix socket as base64 is a megabyte of nothing. (T427.)
        public var files: [String]?
        /// Which model to start it on, where the person has named one. Empty is the CLI's
        /// own default, which is what nearly every agent runs on. (T462.)
        public var model: String?
        /// Which mode to start it in, where the person picked one at launch instead of
        /// letting it follow the floor's setting. A mode the agent turns out not to offer
        /// is ignored and the floor's setting stands. (T466.)
        public var mode: String?

        public init(op: Op, agent: UUID? = nil, kind: String? = nil, cwd: String? = nil,
                    text: String? = nil, requestID: Int? = nil, optionID: String? = nil,
                    words: String? = nil, files: [String]? = nil, model: String? = nil,
                    mode: String? = nil) {
            self.op = op
            self.agent = agent
            self.kind = kind
            self.cwd = cwd
            self.text = text
            self.requestID = requestID
            self.optionID = optionID
            self.words = words
            self.files = files
            self.model = model
            self.mode = mode
        }

        public enum Op: String, Codable, Sendable {
            /// What are you holding? The app's poll, on the refresh it already runs.
            case list
            /// Start this agent here, with these words.
            case start
            /// Pick this conversation back up, `session/load`, with these words after it.
            case resume
            /// Say this to it. A nudge, a message, the status report ask: one path.
            case say
            /// Stop what you are doing, but stay.
            case cancel
            /// Stop and go.
            case stop
            /// The person picked an option on a permission request.
            case permission
            /// The person answered the agent's own question.
            case answer
            /// Put this agent in this mode, whatever the rest of the floor is doing.
            case mode
            /// Join everything waiting into one thing to say, so it goes as one turn
            /// instead of one turn each. (T541.)
            case merge
            /// Are you there? Answers before anything else is touched.
            case ping
            /// Go away, once nothing is running.
            case shutdown
        }
    }

    public struct Reply: Codable, Sendable, Equatable {
        public var ok: Bool
        /// Why not, in words a person reads.
        public var error: String?
        public var agents: [Running]?
        /// The session the agent minted, on a start.
        public var session: String?
        /// The daemon's own process, so the app can say whether the floor is up.
        public var pid: Int32?

        public init(ok: Bool, error: String? = nil, agents: [Running]? = nil,
                    session: String? = nil, pid: Int32? = nil) {
            self.ok = ok
            self.error = error
            self.agents = agents
            self.session = session
            self.pid = pid
        }

        public static func no(_ why: String) -> Reply { Reply(ok: false, error: why) }

        /// What a daemon says to a line it cannot decode. Named because it is also what an
        /// older daemon says to an op added since it started: the daemon holds the agents,
        /// so it is not restarted when the app is rebuilt and can be hours older than the
        /// app talking to it. The caller matches on this to say something better than the
        /// wire's own words. (T541.)
        public static let notARequest = "That was not a request."
        public static var yes: Reply { Reply(ok: true) }
    }

    /// One agent the daemon is holding.
    public struct Running: Codable, Sendable, Equatable, Identifiable {
        public var agent: UUID
        public var state: State
        /// The agent process itself, so the floor can still answer with the kernel when
        /// the daemon is the thing that has gone.
        public var pid: Int32?
        public var session: String?
        public var startedAt: Date
        /// Set when the child has gone, with what it said on the way out.
        public var exit: Int32?
        /// What it will take in a prompt, off its own handshake. (T427.)
        public var takes = ACP.Attachments()
        /// What it can be asked to do, as it lists them. (T436.)
        public var commands: [ACP.Command] = []
        /// What is waiting to be said to it when this turn ends, in the order it will be
        /// said. A count said how many and not what, which is the one thing you want to
        /// know before adding a third. (T465.)
        public var waitingToSay: [String] = []
        /// A question the agent has put to the person, `elicitation/create`. Blocked on
        /// it exactly like a permission request, and put in front of a person the same
        /// way. Only Claude Code sends these. (T373.)
        public var asking: Question?
        /// The request id of a question the agent took back, `elicitation/complete`. It is
        /// not the same as one nobody answered: the agent has said never mind, so the
        /// question stops being asked rather than staying open for a person. Cleared when
        /// the next question arrives. (T493.)
        public var tookBack: Int?
        /// A question it is blocked on. Until this is answered the agent does nothing,
        /// which is what makes it different from every other question on the floor.
        public var waiting: Pending?
        /// Whether a turn is in flight. An agent between turns is waiting for words.
        public var isPrompting: Bool = false
        /// What it is doing, in one line: the tool it is running, else the last thing it
        /// said. This is what the OSC terminal title used to be and it is better, because
        /// it is the truth rather than whatever the CLI put in its window title. The app
        /// writes it onto the record, so every card, row and board reads it the same way
        /// as before. (T373.)
        public var line: String?
        /// How many things are waiting to be said once the turn in flight ends. Nothing
        /// is ever said to an agent mid-turn: of the four, one queues, one drops it
        /// silently and one cancels what it was doing, so the daemon queues for all of
        /// them. (T373.)
        public var queued: Int = 0
        /// The modes this agent offers, as it named them, and the one it is in. Shown on
        /// its page: what an agent may do without asking is per agent, and every one of
        /// these CLIs has its own words for it. (Alex, 16 Sep 2026.)
        public var modes: [ACP.Mode] = []
        public var mode: String?
        /// What the agent says its session is set to: the model, the effort, whatever else
        /// it lists. Read rather than set, and empty for an agent that says nothing.
        /// (R69, T546.)
        public var options: [ACP.ConfigOption] = []

        public var id: UUID { agent }

        public init(agent: UUID, state: State, pid: Int32? = nil, session: String? = nil,
                    startedAt: Date = .now, exit: Int32? = nil, waiting: Pending? = nil,
                    isPrompting: Bool = false, line: String? = nil, queued: Int = 0,
                    asking: Question? = nil, modes: [ACP.Mode] = [], mode: String? = nil) {
            self.agent = agent
            self.state = state
            self.pid = pid
            self.session = session
            self.startedAt = startedAt
            self.exit = exit
            self.waiting = waiting
            self.isPrompting = isPrompting
            self.line = line
            self.queued = queued
            self.asking = asking
            self.modes = modes
            self.mode = mode
        }

        /// Read from whatever the daemon on this Mac happens to be. The daemon outlives
        /// the app: it is the reason an agent survives a rebuild, so every rebuild that
        /// adds a field here is a new app reading an old daemon's words. The synthesised
        /// decoder throws on a missing key even where the property has a default, which
        /// took the whole `list` reply down and left the app with no agents at all: no
        /// mode, no commands, no line, on a floor that was working. A field nobody sent
        /// is its default. (Alex, 15 Sep 2026; the same rule as `Records.version`.)
        ///
        /// **Every field goes in here**, or the daemon sends it and the app silently
        /// reads the default instead. `waitingToSay` and `tookBack` were both missed, so
        /// the words queued for a busy agent and a question it took back never reached
        /// the page: the daemon was right, the socket carried it, and the decoder threw
        /// it away. `everyFieldSurvivesTheRoundTrip` fills one of these in and asserts it
        /// comes back equal, which fails for the next field somebody forgets. (T501.)
        public init(from decoder: any Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            agent = try box.decode(UUID.self, forKey: .agent)
            state = try box.decode(State.self, forKey: .state)
            pid = try box.decodeIfPresent(Int32.self, forKey: .pid)
            session = try box.decodeIfPresent(String.self, forKey: .session)
            startedAt = try box.decodeIfPresent(Date.self, forKey: .startedAt) ?? .now
            exit = try box.decodeIfPresent(Int32.self, forKey: .exit)
            takes = try box.decodeIfPresent(ACP.Attachments.self, forKey: .takes) ?? ACP.Attachments()
            commands = try box.decodeIfPresent([ACP.Command].self, forKey: .commands) ?? []
            waitingToSay = try box.decodeIfPresent([String].self, forKey: .waitingToSay) ?? []
            asking = try box.decodeIfPresent(Question.self, forKey: .asking)
            tookBack = try box.decodeIfPresent(Int.self, forKey: .tookBack)
            waiting = try box.decodeIfPresent(Pending.self, forKey: .waiting)
            isPrompting = try box.decodeIfPresent(Bool.self, forKey: .isPrompting) ?? false
            line = try box.decodeIfPresent(String.self, forKey: .line)
            queued = try box.decodeIfPresent(Int.self, forKey: .queued) ?? 0
            modes = try box.decodeIfPresent([ACP.Mode].self, forKey: .modes) ?? []
            mode = try box.decodeIfPresent(String.self, forKey: .mode)
            options = try box.decodeIfPresent([ACP.ConfigOption].self, forKey: .options) ?? []
        }

        public enum State: String, Codable, Sendable {
            /// Spawned, handshaking, no session yet.
            case starting
            /// It has a session and is ours to talk to.
            case running
            /// The child has gone. The transcript stays.
            case stopped
            /// It never got as far as a session. `exit` and the transcript say why.
            case failed
        }

        public var isAlive: Bool { state == .starting || state == .running }
    }

    /// The agent's own question, flattened into what a person needs to answer it.
    public struct Question: Codable, Sendable, Equatable {
        public var requestID: Int
        public var question: String
        public var options: [Option]
        /// Whether the agent offered somewhere for an answer in the person's own words.
        public var takesWords: Bool
        public var asked: Date

        public init(requestID: Int, question: String, options: [Option],
                    takesWords: Bool, asked: Date = .now) {
            self.requestID = requestID
            self.question = question
            self.options = options
            self.takesWords = takesWords
            self.asked = asked
        }

        public struct Option: Codable, Sendable, Equatable, Identifiable {
            public var value: String
            public var title: String
            public var detail: String
            public var id: String { value }
            public init(value: String, title: String, detail: String) {
                self.value = value
                self.title = title
                self.detail = detail
            }
        }
    }

    /// A permission request the agent is blocked on, flattened into what a person needs
    /// to answer it.
    public struct Pending: Codable, Sendable, Equatable {
        /// The JSON-RPC id to answer. The agent is sitting on this.
        public var requestID: Int
        public var title: String
        public var kind: String?
        public var options: [ACP.PermissionOption]
        public var asked: Date

        public init(requestID: Int, title: String, kind: String? = nil,
                    options: [ACP.PermissionOption], asked: Date = .now) {
            self.requestID = requestID
            self.title = title
            self.kind = kind
            self.options = options
            self.asked = asked
        }

        /// What to take when nobody answers. Allow once: allowing always is a standing
        /// decision and not one to make for somebody who was away from the Mac.
        public var fallback: ACP.PermissionOption? {
            options.first { $0.kind == .allowOnce } ?? options.first { $0.isAllow } ?? options.first
        }
    }

    /// How long a blocked agent waits for a person before the factory takes the
    /// recommended option for it and says so in the decision.
    ///
    /// There has to be a number. A permission request is not a question sitting in a
    /// list: the agent does nothing until it is answered, so an unanswered one at
    /// half past five is an agent that did nothing all evening. Ten minutes is long
    /// enough for somebody at the Mac to see the banner and short enough that nobody
    /// comes back to a floor that has been standing still. (T373.)
    public static let answerWithin: TimeInterval = 10 * 60

    /// What the factory sends for something nobody answered in time.
    public enum Late: Sendable, Equatable {
        /// A permission request, answered with the option the agent marked. Always allow
        /// once, never allow always: a standing decision is not one to make for somebody
        /// because they were away from the Mac.
        case allow(requestID: Int, optionID: String)
        /// The agent's own question, given up on rather than answered. Nothing on the
        /// wire says which option the agent would recommend, so there is nothing to take,
        /// and picking whichever it listed first would be the factory deciding for the
        /// person. The agent carries on; the question stays open for whoever it was for.
        case decline(requestID: Int)
    }

    /// Everything this agent has been waiting on for longer than `answerWithin`.
    ///
    /// A rule rather than a loop inside the floor, so the difference between the two cases
    /// can be read and tested without a pipe on the other end of it. (T421.)
    public static func late(in running: Running, now: Date = .now) -> [Late] {
        var out: [Late] = []
        if let waiting = running.waiting,
           now.timeIntervalSince(waiting.asked) > answerWithin,
           let option = waiting.fallback {
            out.append(.allow(requestID: waiting.requestID, optionID: option.optionID))
        }
        if let asking = running.asking, now.timeIntervalSince(asking.asked) > answerWithin {
            out.append(.decline(requestID: asking.requestID))
        }
        return out
    }

    // MARK: Reading and writing the wire

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode<T: Encodable>(_ value: T) -> Data {
        ((try? encoder.encode(value)) ?? Data()) + Data("\n".utf8)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }
}
#endif
