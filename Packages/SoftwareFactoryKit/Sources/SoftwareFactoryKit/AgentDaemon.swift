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

    /// One log per agent, under the store, beside `agents/` and `tasks/`. It is the
    /// record: the transcript on an agent's page is folded out of this file, which is why
    /// the page has something to show after the app has been rebuilt under it.
    public static func transcriptFolder(in store: FileStore) -> URL {
        let folder = store.root.appending(path: "transcripts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    public static func transcriptFile(for agent: UUID, in store: FileStore) -> URL {
        transcriptFolder(in: store).appending(path: "\(agent.uuidString).jsonl")
    }

    /// Whatever the agent wrote to stderr. Not shown anywhere: it is what you read when
    /// an agent will not start and the transcript is empty, which is the one failure the
    /// protocol itself cannot describe.
    public static func complaintsFile(for agent: UUID, in store: FileStore) -> URL {
        transcriptFolder(in: store).appending(path: "\(agent.uuidString).err")
    }

    /// Whether the transcript folder is really there and really writable. The store is a
    /// group container, and a daemon started outside the app may not be allowed into it,
    /// in which case every log would be silently empty.
    public static func canKeepTranscripts(in store: FileStore) -> Bool {
        let folder = transcriptFolder(in: store)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder),
              isFolder.boolValue else { return false }
        return FileManager.default.isWritableFile(atPath: folder.path)
    }

    /// The lines an agent has sent, for folding into a page. A missing file is an agent
    /// that has not started rather than an error.
    public static func transcriptLines(for agent: UUID, in store: FileStore) -> [String] {
        guard let text = try? String(contentsOf: transcriptFile(for: agent, in: store), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
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

        public init(op: Op, agent: UUID? = nil, kind: String? = nil, cwd: String? = nil,
                    text: String? = nil, requestID: Int? = nil, optionID: String? = nil,
                    words: String? = nil) {
            self.op = op
            self.agent = agent
            self.kind = kind
            self.cwd = cwd
            self.text = text
            self.requestID = requestID
            self.optionID = optionID
            self.words = words
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
        /// A question the agent has put to the person, `elicitation/create`. Blocked on
        /// it exactly like a permission request, and put in front of a person the same
        /// way. Only Claude Code sends these. (T373.)
        public var asking: Question?
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
        public var modes: [Mode] = []
        public var mode: String?

        public var id: UUID { agent }

        public init(agent: UUID, state: State, pid: Int32? = nil, session: String? = nil,
                    startedAt: Date = .now, exit: Int32? = nil, waiting: Pending? = nil,
                    isPrompting: Bool = false, line: String? = nil, queued: Int = 0,
                    asking: Question? = nil, modes: [Mode] = [], mode: String? = nil) {
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

    /// One way an agent can be told to run: its id, and the words it uses for it.
    public struct Mode: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var detail: String?

        public init(id: String, name: String, detail: String? = nil) {
            self.id = id
            self.name = name
            self.detail = detail
        }
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
