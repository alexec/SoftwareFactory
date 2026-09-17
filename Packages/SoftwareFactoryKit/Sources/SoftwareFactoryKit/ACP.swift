import Foundation

/// The Agent Client Protocol, from the client's side. JSON-RPC 2.0 over a pipe, the same
/// wire `MCPServer` already speaks, pointed the other way: there we answer an agent, here
/// we drive one.
///
/// Only the half the factory needs is here. We declare no filesystem and no terminal
/// capability, because these agents are local CLIs standing in the project's folder with
/// their own file tools and their own shell: serving files back to a process that can
/// already open them buys nothing and is a third of the protocol.
///
/// The shapes are taken from a real session rather than from the documentation, which
/// disagrees with the wire in a few places that matter: the permission outcome is
/// `selected` and not `Approved`, a stop reason is `end_turn` and not `Completed`.
/// `Tests/ACPTranscriptTests` replays that recording. (T373.)
///
/// **What is out, and why.** Audited against the protocol's own method list on
/// 15 September 2026 and written down here so the next reader finds a decision rather than
/// a hole. (T493.)
///
/// - `fs/read_text_file`, `fs/write_text_file` and every `terminal/*` method: declared
///   false at the handshake and meant to stay that way. These agents are local CLIs
///   standing in the project's folder with their own file tools and their own shell.
///   A call for one of them is an agent ignoring what we said, so it is refused with
///   -32601 and the refusal is written to the agent's complaints file. (T491.)
/// - `authenticate`: read but never called. `ACP.WayIn` takes `authMethods` off the
///   handshake and uses it to say which command to run when a start fails, which is the
///   whole of what a person needs today (T435). Doing it properly wants `auth.terminal`
///   declared and the terminal methods we just declined, so it is a decision to take
///   rather than a gap to fill.
/// - `logout` and `session/delete`: never called. Deleting an agent kills its process and
///   leaves whatever session state its CLI keeps on disk. Worth having when a person
///   complains about the disk, and not before.
/// - `providers` and model selection: not in the version we target. A model is chosen at
///   launch instead, as a flag or an environment variable per CLI, which is where it is
///   possible at all (T462).
/// - `session.configOptions`: newer than what we read.
/// - `PlanEntry.priority`, and `rawInput`/`rawOutput` on a tool call: decoded or not and
///   drawn nowhere. A plan is already a row of chips that tick themselves off, and the raw
///   arguments of a tool call are the machine talking to itself.
/// - Images and audio coming back from an agent are still the strings `[image]` and
///   `[audio]`. We send images up (T427) and this is the way back down; it is the one
///   thing on this list worth building next, because a screenshot an agent hands over
///   should be a screenshot. See T317.
public enum ACP {
    /// The version the factory speaks. An integer, not a date string like MCP's.
    public static let protocolVersion = 1

    // MARK: What we send

    /// The opening handshake. The agent answers with what it can do.
    public static func initialize() -> [String: Any] {
        [
            "protocolVersion": protocolVersion,
            "clientCapabilities": clientCapabilities,
            "clientInfo": ["name": "software-factory", "version": MCPServer.version],
        ]
    }

    /// A new conversation, standing in the project's folder, holding the factory's own
    /// MCP server. This is the plugin install that no longer has to happen: the agent is
    /// handed the factory at the moment it starts. (T373.)
    public static func newSession(cwd: String, mcpServers: [[String: Any]]) -> [String: Any] {
        ["cwd": cwd, "mcpServers": mcpServers]
    }

    /// Picking a conversation back up, for an agent that says it can. Same arguments as
    /// a new one, plus the id we kept.
    public static func loadSession(_ id: String, cwd: String, mcpServers: [[String: Any]]) -> [String: Any] {
        ["sessionId": id, "cwd": cwd, "mcpServers": mcpServers]
    }

    /// Our MCP server as the agent should reach it: over HTTP on the loopback, because
    /// the app is already serving there and a second stdio copy would be a second store
    /// reader for no reason.
    /// `headers` is an empty array and not an omitted field: the agent validates the
    /// whole shape and answers "Invalid params" for a missing one, which says nothing
    /// about which field it meant. (T373.)
    public static func factoryServer(agent: UUID? = nil, port: Int = 4747) -> [String: Any] {
        // Each agent gets its own address, so the factory knows who is calling and the
        // agent never has to say. That is `session_id` off all thirty-three tools. (T373.)
        let path = agent.map { "/mcp/\($0.uuidString)" } ?? "/mcp"
        return ["type": "http", "name": MCPServer.name, "url": "http://127.0.0.1:\(port)\(path)", "headers": []]
    }

    /// Words for the agent. Everything the factory says to one goes through here: the
    /// launch prompt, a nudge, a message from another agent, the status report ask.
    public static func prompt(_ text: String, session: String) -> [String: Any] {
        ["sessionId": session, "prompt": [["type": "text", "text": text]]]
    }

    /// What an agent said it will take in a prompt, off its handshake.
    ///
    /// Per agent and not the same twice, which is why this is read rather than assumed:
    /// measured on 15 Sep 2026, Grok takes no image at all and Cursor takes no embedded
    /// resource, so the two that refuse something refuse different halves. Text is not in
    /// here because text is the one thing every agent takes. (T427, off the grid in T428.)
    public struct Attachments: Codable, Sendable, Equatable {
        public var image: Bool
        public var embeddedContext: Bool

        public init(image: Bool = false, embeddedContext: Bool = false) {
            self.image = image
            self.embeddedContext = embeddedContext
        }

        public static func read(_ result: [String: Any]) -> Attachments {
            let caps = (result["agentCapabilities"] as? [String: Any])?["promptCapabilities"] as? [String: Any]
            return Attachments(image: caps?["image"] as? Bool ?? false,
                               embeddedContext: caps?["embeddedContext"] as? Bool ?? false)
        }
    }

    /// A way in, as the agent declares it at handshake.
    ///
    /// Three of the four declare one and the factory calls `authenticate` for none of
    /// them, which is fine while they are logged in and useless when they are not: the
    /// start fails at `session/new` and the app has nothing to say about why. This is not
    /// a login flow. It is the difference between "it did not start" and "Copilot is not
    /// logged in, run copilot login". (T435, off the grid in T428.)
    public struct WayIn: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var detail: String?
        /// The command the agent says to run, where it says one. Copilot hands this over
        /// in `_meta.terminal-auth`; the others describe it in words instead.
        public var command: String?

        public init(id: String, name: String, detail: String? = nil, command: String? = nil) {
            self.id = id
            self.name = name
            self.detail = detail
            self.command = command
        }

        public static func read(_ result: [String: Any]) -> [WayIn] {
            (result["authMethods"] as? [[String: Any]] ?? []).compactMap { one in
                guard let id = one["id"] as? String else { return nil }
                let terminal = (one["_meta"] as? [String: Any])?["terminal-auth"] as? [String: Any]
                let command = (terminal?["command"] as? String).map { binary in
                    ([binary] + ((terminal?["args"] as? [String]) ?? [])).joined(separator: " ")
                }
                return WayIn(id: id, name: one["name"] as? String ?? id,
                             detail: one["description"] as? String, command: command)
            }
        }
    }

    /// Why a start failed, in words for the person, given what the agent said it needs.
    ///
    /// Only where there is a way in to name: an agent that declares none, which is Claude
    /// Code here, fails for some other reason and this must not claim otherwise.
    public static func whyItWouldNotStart(_ trouble: String, kind: String, ways: [WayIn]) -> String {
        guard let way = ways.first else { return trouble }
        if let command = way.command {
            return "\(kind) would not start, and it is asking to be logged in. Run: \(command)"
        }
        let how = way.detail ?? way.name
        return "\(kind) would not start, and it is asking to be logged in. \(how)"
    }

    /// One thing a person has dropped on an agent: a picture, or a file of words.
    public enum Attachment: Sendable, Equatable {
        /// An image, as the bytes the agent is given and the type they are in.
        case image(data: Data, mimeType: String, name: String)
        /// A file of words: its path, and what is in it.
        case words(path: String, text: String, name: String)
    }

    /// What to send, given what this agent takes. Nil when there is no honest way to send
    /// it, and the second half of the answer is why, in words for the person.
    ///
    /// A picture degrades to nothing: an agent that cannot see one cannot be told about it
    /// in a way that helps, and a filename in its place is a worse answer than saying so.
    /// A file of words degrades to words, because every agent takes text and a file read
    /// into the prompt is what an embedded resource is carrying anyway. (T427.)
    public static func block(for attachment: Attachment, takes: Attachments)
        -> (block: [String: Any]?, refusal: String?) {
        switch attachment {
        case .image(let data, let mimeType, let name):
            guard takes.image else {
                return (nil, "This agent does not take images, so \(name) was not sent.")
            }
            return (["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType], nil)
        case .words(let path, let text, let name):
            guard takes.embeddedContext else {
                // Every agent takes text, so the file goes in as text rather than not at
                // all. It says which file it is, because a wall of someone else's code
                // with no name on it is a puzzle.
                return (["type": "text", "text": "\(name):\n\n\(text)"], nil)
            }
            return (["type": "resource",
                     "resource": ["uri": "file://\(path)", "text": text, "mimeType": "text/plain"]], nil)
        }
    }

    /// A prompt with things attached to it. The words go first, because they are what the
    /// person is saying and the attachments are what they are saying it about.
    public static func prompt(_ text: String, attaching blocks: [[String: Any]],
                              session: String) -> [String: Any] {
        var prompt: [[String: Any]] = []
        if !text.isEmpty { prompt.append(["type": "text", "text": text]) }
        prompt.append(contentsOf: blocks)
        if prompt.isEmpty { prompt.append(["type": "text", "text": ""]) }
        return ["sessionId": session, "prompt": prompt]
    }

    /// One way an agent can be told to run: its id, and the words it uses for it.
    ///
    /// Here rather than on the daemon, because a session mode is the protocol's idea and
    /// the daemon is macOS only: the phone builds this package too, and putting it there
    /// took the whole phone build down. (Alex, 16 Sep 2026.)
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

    /// Which mode the session runs in, `session/set_mode`.
    public static func setMode(_ mode: String, session: String) -> [String: Any] {
        ["sessionId": session, "modeId": mode]
    }

    /// One thing about a session the agent says is set, and to what: how much it may do,
    /// which model it is on, how hard it is thinking.
    ///
    /// Read rather than set. The agent lists these at `session/new` with a current value
    /// each, and the factory shows them so a person can see how an agent is configured
    /// without reading a launch command. Setting one is a different piece of work and needs
    /// a method we have not seen an agent offer. (R69, T546.)
    public struct ConfigOption: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var detail: String?
        /// What it is set to, in the agent's own words where it gave them: the name of the
        /// chosen option rather than its id, because "Bypass permissions" is what a person
        /// reads and "bypassPermissions" is what the wire carries.
        public var value: String?
        /// What else it could be, for a person judging whether the current value is the
        /// interesting one. Names, not ids, for the same reason.
        public var choices: [String] = []

        public init(id: String, name: String, detail: String? = nil,
                    value: String? = nil, choices: [String] = []) {
            self.id = id
            self.name = name
            self.detail = detail
            self.value = value
            self.choices = choices
        }
    }

    /// The session options in a `session/new` or `session/load` answer.
    ///
    /// `ACP.swift`'s own audit said of `configOptions` that it was "newer than what we
    /// read". It was not: the adapter on this Mac has been sending it on every session all
    /// along, four options with their current values, and two of them, effort and fast
    /// mode, are reachable nowhere else in the factory. Measured off 44 transcripts rather
    /// than read, which is how the note turned out to be wrong. (R69.)
    ///
    /// An agent that sends none gets an empty list and the panel says it did not say, the
    /// same as everything else here: only Claude Code's adapter is known to send these, and
    /// three of the four CLIs have never been asked.
    public static func options(in result: [String: Any]) -> [ConfigOption] {
        guard let listed = result["configOptions"] as? [[String: Any]] else { return [] }
        return listed.compactMap { one in
            guard let id = one["id"] as? String else { return nil }
            let choices = (one["options"] as? [[String: Any]]) ?? []
            let current = one["currentValue"]
            let named = choices.first { option in
                guard let value = option["value"] else { return false }
                return String(describing: value) == String(describing: current ?? "")
            }
            return ConfigOption(
                id: id,
                name: one["name"] as? String ?? id,
                detail: one["description"] as? String,
                value: named?["name"] as? String ?? (current.map { String(describing: $0) }),
                choices: choices.compactMap { $0["name"] as? String ?? $0["value"] as? String })
        }
    }

    /// The modes an agent offered at `session/new`, and which one asks the fewest
    /// questions.
    ///
    /// This is the difference between the factory answering every permission request
    /// instantly and the agent never asking one. Claude Code offers `bypassPermissions`,
    /// "Accepts all permissions", which is what every agent was launched with before ACP.
    /// Copilot's modes are about how it converses rather than what it may do, and Grok has
    /// none at all, so for those two the answer stays "say yes quickly". (T373, and Alex,
    /// 16 Sep 2026: can we enable auto-permission mode for Claude.)
    public enum Modes {
        /// Most permissive first. Matched by id, because the names are prose and the
        /// descriptions are prose about the prose.
        static let permissiveFirst = ["bypassPermissions", "auto", "acceptEdits"]
        /// The agent judging for itself, which is a different thing from being told yes
        /// to everything, and every one of these CLIs offers both.
        static let deciding = ["auto", "acceptEdits"]

        /// The modes in a `session/new` or `session/load` answer.
        public static func offered(in result: [String: Any]) -> [String] {
            listed(in: result).map(\.id)
        }

        /// The same, with the words the agent uses for them, for a menu a person reads.
        public static func listed(in result: [String: Any]) -> [Mode] {
            guard let modes = result["modes"] as? [String: Any],
                  let available = modes["availableModes"] as? [[String: Any]]
            else { return [] }
            return available.compactMap { one in
                guard let id = one["id"] as? String else { return nil }
                return Mode(id: id, name: one["name"] as? String ?? id,
                            detail: one["description"] as? String)
            }
        }

        public static func current(in result: [String: Any]) -> String? {
            (result["modes"] as? [String: Any])?["currentModeId"] as? String
        }

        /// The one to ask for, given how much the person said an agent may do. Nil when
        /// the agent offers nothing better than what it is already in.
        public static func wanted(_ permissions: Throttle.Permissions, from offered: [String]) -> String? {
            switch permissions {
            case .allowEverything:
                return permissiveFirst.first { offered.contains($0) }
            case .agentDecides:
                return deciding.first { offered.contains($0) }
            case .askAboutChanges, .askAboutEverything:
                // Back to asking, so the factory gets to decide each one.
                return offered.contains("default") ? "default" : nil
            }
        }
    }

    /// Stop what you are doing. A notification: there is no answer to wait for.
    public static func cancel(session: String) -> [String: Any] {
        ["sessionId": session]
    }

    /// Our answer to a permission request: the option the person picked.
    public static func permissionAnswer(optionID: String) -> [String: Any] {
        ["outcome": ["outcome": "selected", "optionId": optionID]]
    }

    /// Our answer when nobody is going to pick: the agent stops rather than waits.
    public static var permissionCancelled: [String: Any] { ["outcome": ["outcome": "cancelled"]] }

    // MARK: What we read

    /// One line off the agent's pipe, sorted into the four things it can be. Anything we
    /// do not recognise is kept rather than dropped: a protocol that adds an update kind
    /// next month should not make the transcript lie about what happened.
    public enum Incoming: Sendable {
        /// The answer to something we asked, by the id we asked it with.
        case response(id: Int, result: Data?, error: Failure?)
        /// The agent narrating: `session/update`.
        case update(session: String, Update)
        /// The agent asking before it acts. It is blocked until we answer this id.
        case permission(id: Int, PermissionRequest)
        /// The agent asking the person a question, `elicitation/create`. Blocked on this
        /// id the same way, and put in front of a person the same way.
        case question(id: Int, Elicitation)
        /// Something else addressed to us that expects an answer. We answer it with
        /// -32601 rather than leaving the agent waiting, and rather than the empty success
        /// it used to get, which told a caller its file had been read. (T491.)
        case request(id: Int, method: String)
        /// The agent has taken its question back. No answer is wanted; the question should
        /// stop being asked. Nil when it did not say which, which means the one it is
        /// blocked on, because it can only be blocked on one. (T493.)
        case withdrawn(id: Int?)
        /// Something the agent is telling us that wants no answer, like
        /// `_auth/status_update`. Nothing to do, and not the same thing as a line we
        /// could not read: answering it would be wrong and worrying about it is noise.
        case notification(method: String)
        /// A line we could not place. Kept so the raw log is still the whole truth.
        case unrecognised(String)
    }

    public struct Failure: Codable, Sendable, Equatable {
        public var code: Int
        public var message: String
        public init(code: Int, message: String) {
            self.code = code
            self.message = message
        }
    }

    /// Reads one line. Never throws: a malformed line becomes `.unrecognised`, because a
    /// client that falls over on a stray byte takes the agent down with it.
    public static func read(line: String) -> Incoming {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unrecognised(line) }

        let method = object["method"] as? String
        let id = object["id"] as? Int

        if let method {
            switch method {
            case "session/update":
                guard let params = object["params"] as? [String: Any],
                      let session = params["sessionId"] as? String,
                      let update = params["update"],
                      let body = try? JSONSerialization.data(withJSONObject: update),
                      let decoded = try? decoder.decode(Update.self, from: body)
                else { return .unrecognised(line) }
                return .update(session: session, decoded)
            case "elicitation/create":
                guard let id, let params = object["params"] as? [String: Any],
                      let asked = Elicitation.read(params)
                else { return .unrecognised(line) }
                return .question(id: id, asked)
            case "session/request_permission":
                guard let id, let params = object["params"],
                      let body = try? JSONSerialization.data(withJSONObject: params),
                      let decoded = try? decoder.decode(PermissionRequest.self, from: body)
                else { return .unrecognised(line) }
                return .permission(id: id, decoded)
            // An agent withdrawing a question it asked. It arrives as a notification, so
            // there is nothing to answer; what it needs is the question taken down, or it
            // sits on the Needs you strip and the Lock Screen with nobody on the other end.
            // (T493, off A82's audit.)
            case "elicitation/complete":
                return .withdrawn(id: (object["params"] as? [String: Any])?["id"] as? Int)
            default:
                guard let id else { return .notification(method: method) }
                return .request(id: id, method: method)
            }
        }

        guard let id else { return .unrecognised(line) }
        if let error = object["error"] as? [String: Any] {
            return .response(id: id, result: nil, error: Failure(
                code: error["code"] as? Int ?? 0,
                message: error["message"] as? String ?? "The agent said no and did not say why."))
        }
        let result = (object["result"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return .response(id: id, result: result, error: nil)
    }

    static let decoder = JSONDecoder()

    // MARK: The updates

    /// What the agent says it is doing. The names are the wire's own, snake cased, and
    /// the discriminator is `sessionUpdate`.
    public enum Update: Sendable, Equatable {
        /// A piece of what the agent is saying out loud. They arrive a word at a time.
        case message(ContentBlock)
        /// A piece of what it is thinking. Kept apart because a page shows the two
        /// differently: thinking is foldable, saying is not.
        case thought(ContentBlock)
        /// Our own words echoed back, which `session/load` uses to replay a conversation.
        case userMessage(ContentBlock)
        /// A tool the agent has started, or news about one already started.
        case tool(ToolCall)
        /// What it means to do, as a list that ticks itself off.
        case plan([PlanEntry])
        /// How much of its context it has used.
        case usage(used: Int, size: Int)
        /// What it can be asked to do: its own commands, as it lists them. They arrive
        /// when a session starts and again whenever the set changes. (T436.)
        case commands([Command])
        /// The mode it is in now. The factory sets a mode with `session/set_mode` and used
        /// to hear nothing back, so an agent that changed its own, or whose set_mode did
        /// not take, left the menu on its page naming a mode it was not in. (T426.)
        case mode(String)
        /// Something in the protocol we do not draw: available commands, the mode it is
        /// in, its settings. Carried so the raw log stays honest.
        case other(String)

        enum Keys: String, CodingKey { case sessionUpdate }
    }

    /// One thing an agent can be asked to do in its own words: a slash command, a skill,
    /// whatever that CLI calls them. The description is the agent's and can run to a
    /// paragraph, so `brief` is what a menu shows. (T436.)
    public struct Command: Codable, Sendable, Equatable, Identifiable {
        public var name: String
        public var description: String?
        /// What the command takes after its name, in the agent's own words: `/loop` says
        /// `[interval] [prompt]`, `/code-review` says its levels and flags. A quarter of the
        /// commands on this Mac carry one and nothing drew it, so a list of commands said
        /// what each was called and not how to use it. (R69, T546.)
        public var hint: String?

        public var id: String { name }

        public init(name: String, description: String? = nil, hint: String? = nil) {
            self.name = name
            self.description = description
            self.hint = hint
        }

        enum Keys: String, CodingKey { case name, description, input, hint }

        /// The hint arrives nested, as `input: { hint: … }`, and is written back flat,
        /// because the daemon's socket is ours and a second level of box on it buys nothing.
        /// An agent that sends `input: null`, which is three quarters of them, has no hint
        /// rather than a broken record.
        public init(from decoder: any Decoder) throws {
            let box = try decoder.container(keyedBy: Keys.self)
            name = try box.decode(String.self, forKey: .name)
            description = try box.decodeIfPresent(String.self, forKey: .description)
            if let nested = try? box.nestedContainer(keyedBy: Keys.self, forKey: .input) {
                hint = try? nested.decodeIfPresent(String.self, forKey: .hint)
            } else {
                hint = try box.decodeIfPresent(String.self, forKey: .hint)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var box = encoder.container(keyedBy: Keys.self)
            try box.encode(name, forKey: .name)
            try box.encodeIfPresent(description, forKey: .description)
            try box.encodeIfPresent(hint, forKey: .hint)
        }

        /// The first sentence, which is as much as a row of a menu can hold.
        public var brief: String? {
            guard let description, !description.isEmpty else { return nil }
            let first = description.split(separator: ".", maxSplits: 1,
                                          omittingEmptySubsequences: true).first
            return (first.map(String.init) ?? description).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// What goes in the field when you pick it.
        public var typed: String { "/\(name) " }
    }

    /// Completing a command as it is typed, in the field where you are already typing.
    ///
    /// T366 took completions off the add-a-task field and deleted the work types' own
    /// list, on the argument that a row of words under a field is something to read and
    /// dismiss on every task you add. That argument does not carry here and this is not a
    /// quiet reversal of it. The seven work types are a fixed set learned once; an agent's
    /// commands are per agent, change with the CLI, and nobody can be expected to know
    /// them, which is why there is a menu of them at all. What T366 objected to was a list
    /// appearing unbidden on every keystroke; this one appears only after a "/", which is
    /// somebody asking for it, and goes the moment the word stops matching. (T494.)
    public enum Slash {
        /// What is being typed after a leading slash, or nil when the field is not asking
        /// for a command: no slash at the front, or the word already finished with a space,
        /// because a slash in the middle of a sentence is a slash.
        public static func token(in text: String) -> String? {
            guard text.hasPrefix("/") else { return nil }
            let rest = text.dropFirst()
            guard !rest.contains(" "), !rest.contains("\n") else { return nil }
            return String(rest)
        }

        /// The commands to offer for what has been typed so far.
        public static func matches(for text: String, in commands: [Command]) -> [Command] {
            guard let token = token(in: text) else { return [] }
            guard !token.isEmpty else { return commands }
            return commands.filter { $0.name.lowercased().hasPrefix(token.lowercased()) }
        }

        /// The field after picking one: the command and a space, with anything already
        /// typed after the word kept. Picking is not sending, because a command usually
        /// wants something after it.
        public static func picked(_ command: Command, in text: String) -> String {
            guard token(in: text) != nil else { return text }
            return command.typed
        }
    }

    public struct PlanEntry: Codable, Sendable, Equatable, Identifiable {
        public var title: String
        public var status: String
        public var priority: String?
        public var id: String { title }
        public init(title: String, status: String, priority: String? = nil) {
            self.title = title
            self.status = status
            self.priority = priority
        }
        public var isDone: Bool { status == "completed" }
        public var isRunning: Bool { status == "in_progress" }
    }

    /// A tool call, as the agent reports it and then updates it. The first message
    /// carries the title and the kind, and the ones after it carry only what changed, so
    /// everything but the id is optional and `ToolCall.merged(with:)` is how they add up.
    public struct ToolCall: Codable, Sendable, Equatable, Identifiable {
        public var toolCallID: String
        public var title: String?
        public var kind: Kind?
        public var status: Status?
        public var content: [Content]?
        public var locations: [Location]?

        public var id: String { toolCallID }

        enum CodingKeys: String, CodingKey {
            case toolCallID = "toolCallId"
            case title, kind, status, content, locations
        }

        public init(toolCallID: String, title: String? = nil, kind: Kind? = nil, status: Status? = nil,
                    content: [Content]? = nil, locations: [Location]? = nil) {
            self.toolCallID = toolCallID
            self.title = title
            self.kind = kind
            self.status = status
            self.content = content
            self.locations = locations
        }

        /// A later message about the same call, folded onto the one we have. Only the
        /// fields it carried are taken: a status-only update must not wipe the title.
        public func merged(with later: ToolCall) -> ToolCall {
            var out = self
            if let t = later.title { out.title = t }
            if let k = later.kind { out.kind = k }
            if let s = later.status { out.status = s }
            if let c = later.content, !c.isEmpty { out.content = (out.content ?? []) + c }
            if let l = later.locations { out.locations = l }
            return out
        }

        /// What the person is shown for this call.
        ///
        /// Three things get in the way of just using `title`. A call's first message often
        /// carries the raw tool name, `read_file` or `apply_patch`, and only the update
        /// that follows replaces it with a sentence, so the row reads like a function
        /// reference for as long as the call is running, which is exactly when somebody is
        /// looking at it. Grok never sends anything else, because its calls carry no kind
        /// either. And every one of them puts absolute paths in, so a row is nine tenths
        /// somebody's home folder.
        ///
        /// So: a real title has its paths shortened to file names, and a bare tool name
        /// becomes a sentence with the file it is working on. (Alex, 16 Sep 2026.)
        public var heading: String {
            let given = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !given.isEmpty, !Self.isBareToolName(given) { return Self.shortenPaths(in: given) }
            let verb = given.isEmpty ? (kind?.title ?? "Working") : Self.inWords(given)
            guard let path = locations?.first?.path, !path.isEmpty else { return verb }
            return "\(verb) \(Self.fileName(path))"
        }

        /// Whether this is the name of a function rather than something written for a
        /// person: one word, no spaces, lower case, the way every CLI names its tools.
        static func isBareToolName(_ title: String) -> Bool {
            guard !title.contains(" ") else { return false }
            return title == title.lowercased() && !title.contains("/") && !title.contains(".")
        }

        /// A tool name as a person would say it. The common ones are named because the
        /// guess is bad for exactly the calls that happen most; anything else has its
        /// underscores taken out and is left alone.
        static func inWords(_ name: String) -> String {
            let plain = name.lowercased()
                .replacingOccurrences(of: "_tool", with: "")
                .replacingOccurrences(of: "-", with: "_")
            switch plain {
            case "read", "read_file", "view", "view_file", "cat", "open": return "Reading"
            case "write", "write_file", "create", "create_file", "apply_patch", "edit",
                 "edit_file", "str_replace", "multi_edit", "patch": return "Editing"
            case "delete", "delete_file", "remove", "rm": return "Deleting"
            case "move", "rename", "mv": return "Moving"
            case "search", "grep", "glob", "find", "codebase_search", "ripgrep": return "Searching"
            case "bash", "shell", "run", "run_command", "exec", "terminal": return "Running"
            case "fetch", "web_fetch", "http", "curl": return "Fetching"
            case "list", "ls", "list_dir", "list_files": return "Listing"
            case "think", "thinking", "plan", "todo", "todo_write": return "Thinking"
            default:
                let words = plain.split(separator: "_").map(String.init)
                guard let first = words.first else { return "Working" }
                return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
                    .joined(separator: " ")
            }
        }

        /// The last component of a path, or the whole thing when it is not one.
        static func fileName(_ path: String) -> String {
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "`'\"<> "))
            guard trimmed.contains("/") else { return trimmed }
            return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        }

        /// Any absolute path inside a sentence, cut down to its file name. An agent writes
        /// "Read `/Users/someone/very/long/way/down/README.md`" and a row has space for
        /// about a third of that, all of it the part that is the same every time.
        static func shortenPaths(in title: String) -> String {
            title.split(separator: " ", omittingEmptySubsequences: false).map { piece -> String in
                let word = String(piece)
                guard word.contains("/"), word.count > 24 else { return word }
                let lead = word.prefix { $0 == "`" || $0 == "\"" || $0 == "'" || $0 == "(" }
                let tail = String(word.reversed().prefix { $0 == "`" || $0 == "\"" || $0 == "'" || $0 == ")" || $0 == "." || $0 == "," }.reversed())
                let bare = String(word.dropFirst(lead.count).dropLast(tail.count))
                return lead + fileName(bare) + tail
            }.joined(separator: " ")
        }

        public var isFinished: Bool { status == .completed || status == .failed }

        /// What kind of thing it is, which is all the page needs to pick an icon and
        /// decide whether it is worth asking a person about.
        public enum Kind: String, Codable, Sendable, Equatable {
            case read, edit, delete, move, search, execute, think, fetch, other
            public init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Kind(rawValue: raw) ?? .other
            }
            public var title: String {
                switch self {
                case .read: "Reading"
                case .edit: "Editing"
                case .delete: "Deleting"
                case .move: "Moving"
                case .search: "Searching"
                case .execute: "Running"
                case .think: "Thinking"
                case .fetch: "Fetching"
                case .other: "Working"
                }
            }
            /// Whether this is a thing the factory would ever stop to ask about. Reading
            /// and searching are not: an agent that has to ask before it looks at a file
            /// is an agent nobody will leave running. (T373.)
            public var changesAnything: Bool {
                switch self {
                case .read, .search, .think, .fetch: false
                case .edit, .delete, .move, .execute, .other: true
                }
            }
        }

        public enum Status: String, Codable, Sendable, Equatable {
            case pending, inProgress = "in_progress", completed, failed
            public init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Status(rawValue: raw) ?? .pending
            }
        }

        /// What a call produced. A diff is the one worth drawing as itself.
        public enum Content: Codable, Sendable, Equatable {
            case text(String)
            case diff(Diff)
            case terminal(String)
            case other

            enum Keys: String, CodingKey { case type, content, text, path, oldText, newText, terminalId }

            public init(from decoder: Decoder) throws {
                let box = try decoder.container(keyedBy: Keys.self)
                switch try box.decodeIfPresent(String.self, forKey: .type) ?? "" {
                case "diff":
                    self = .diff(Diff(
                        path: try box.decodeIfPresent(String.self, forKey: .path) ?? "",
                        oldText: try box.decodeIfPresent(String.self, forKey: .oldText),
                        newText: try box.decodeIfPresent(String.self, forKey: .newText) ?? ""))
                case "terminal":
                    self = .terminal(try box.decodeIfPresent(String.self, forKey: .terminalId) ?? "")
                case "content":
                    let inner = try? box.nestedContainer(keyedBy: Keys.self, forKey: .content)
                    self = .text(try inner?.decodeIfPresent(String.self, forKey: .text) ?? "")
                default:
                    self = .other
                }
            }

            public func encode(to encoder: Encoder) throws {
                var box = encoder.container(keyedBy: Keys.self)
                switch self {
                case .text(let text):
                    try box.encode("content", forKey: .type)
                    var inner = box.nestedContainer(keyedBy: Keys.self, forKey: .content)
                    try inner.encode("text", forKey: .type)
                    try inner.encode(text, forKey: .text)
                case .diff(let diff):
                    try box.encode("diff", forKey: .type)
                    try box.encode(diff.path, forKey: .path)
                    try box.encodeIfPresent(diff.oldText, forKey: .oldText)
                    try box.encode(diff.newText, forKey: .newText)
                case .terminal(let id):
                    try box.encode("terminal", forKey: .type)
                    try box.encode(id, forKey: .terminalId)
                case .other:
                    try box.encode("other", forKey: .type)
                }
            }
        }
    }

    public struct Diff: Codable, Sendable, Equatable {
        public var path: String
        public var oldText: String?
        public var newText: String
        public init(path: String, oldText: String?, newText: String) {
            self.path = path
            self.oldText = oldText
            self.newText = newText
        }
        /// The file's name on its own, for a heading that is not a hundred characters of
        /// somebody's home folder.
        public var fileName: String { (path as NSString).lastPathComponent }
        /// Lines added and taken away, for the line above the diff.
        public var counts: (added: Int, removed: Int) {
            let old = (oldText ?? "").isEmpty ? [] : (oldText ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            let new = newText.isEmpty ? [] : newText.split(separator: "\n", omittingEmptySubsequences: false)
            return (new.count, old.count)
        }
    }

    public struct Location: Codable, Sendable, Equatable {
        public var path: String
        public var line: Int?
        public init(path: String, line: Int? = nil) {
            self.path = path
            self.line = line
        }
    }

    /// A piece of what somebody said. Text is the only kind the factory draws; the rest
    /// are named so they are not mistaken for nothing.
    public enum ContentBlock: Codable, Sendable, Equatable {
        case text(String)
        case image
        case audio
        case resource(String)

        enum Keys: String, CodingKey { case type, text, uri, name }

        public var text: String {
            switch self {
            case .text(let t): t
            case .image: "[image]"
            case .audio: "[audio]"
            case .resource(let name): "[\(name)]"
            }
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: Keys.self)
            switch try box.decodeIfPresent(String.self, forKey: .type) ?? "text" {
            case "image": self = .image
            case "audio": self = .audio
            case "resource", "resource_link":
                let name = try box.decodeIfPresent(String.self, forKey: .name)
                    ?? box.decodeIfPresent(String.self, forKey: .uri) ?? "attachment"
                self = .resource(name)
            default:
                self = .text(try box.decodeIfPresent(String.self, forKey: .text) ?? "")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: Keys.self)
            switch self {
            case .text(let t):
                try box.encode("text", forKey: .type)
                try box.encode(t, forKey: .text)
            case .image: try box.encode("image", forKey: .type)
            case .audio: try box.encode("audio", forKey: .type)
            case .resource(let name):
                try box.encode("resource_link", forKey: .type)
                try box.encode(name, forKey: .name)
            }
        }
    }

    /// The agent asking before it does something. It is blocked on our answer, which is
    /// the fact that shapes everything downstream: an unanswered question here is not a
    /// question sitting in a list, it is an agent doing nothing. (T373.)
    public struct PermissionRequest: Codable, Sendable, Equatable {
        public var sessionID: String
        public var toolCall: ToolCall
        public var options: [PermissionOption]

        enum CodingKeys: String, CodingKey {
            case sessionID = "sessionId"
            case toolCall, options
        }

        public init(sessionID: String, toolCall: ToolCall, options: [PermissionOption]) {
            self.sessionID = sessionID
            self.toolCall = toolCall
            self.options = options
        }

        /// The one to take when nobody answers in time, and the one the question is
        /// filed recommending: allow it once. Allowing always is a standing decision and
        /// not one to make on a person's behalf because they were away from the Mac.
        public var recommended: PermissionOption? {
            options.first { $0.kind == .allowOnce } ?? options.first { $0.isAllow } ?? options.first
        }

        public var denial: PermissionOption? {
            options.first { !$0.isAllow }
        }
    }

    public struct PermissionOption: Codable, Sendable, Equatable, Identifiable {
        public var optionID: String
        public var name: String
        public var kind: Kind

        public var id: String { optionID }

        enum CodingKeys: String, CodingKey {
            case optionID = "optionId"
            case name, kind
        }

        public init(optionID: String, name: String, kind: Kind) {
            self.optionID = optionID
            self.name = name
            self.kind = kind
        }

        public var isAllow: Bool { kind == .allowOnce || kind == .allowAlways }

        public enum Kind: String, Codable, Sendable, Equatable {
            case allowOnce = "allow_once"
            case allowAlways = "allow_always"
            case rejectOnce = "reject_once"
            case rejectAlways = "reject_always"
            case other
            public init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Kind(rawValue: raw) ?? .other
            }
        }
    }

    /// Whether this line is a turn ending: the answer to `session/prompt`, which carries a
    /// `stopReason` and nothing else we read.
    ///
    /// It is the one place in a log where nothing is half-said. Every tool call the agent
    /// opened during that turn has had the update that names it, no message chunk is
    /// mid-sentence, and the agent is about to be quiet. That is what makes it the place to
    /// cut a log when a page opens at the end of one rather than at the beginning: a fold
    /// starting just after a turn ended cannot meet an update for a call it never saw.
    ///
    /// Read off the line rather than decoded into a type, because the only thing being
    /// asked is whether the field is there. A turn that ended for a reason we have never
    /// heard of still ended. (T511.)
    public static func endsATurn(line: String) -> Bool {
        guard case .response(_, let result, _) = read(line: line), let result,
              let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any]
        else { return false }
        return object["stopReason"] != nil
    }

    /// Why a turn ended. `end_turn` is the ordinary one; the rest are worth showing.
    public enum StopReason: String, Sendable {
        case endTurn = "end_turn"
        case maxTokens = "max_tokens"
        case maxTurnRequests = "max_turn_requests"
        case refusal
        case cancelled
        case unknown

        public init(_ raw: String?) {
            self = StopReason(rawValue: raw ?? "") ?? .unknown
        }

        /// What the page says under a turn that did not simply finish. Nil for the
        /// ordinary end, which needs no announcement.
        public var note: String? {
            switch self {
            case .endTurn, .unknown: nil
            case .maxTokens: "It ran out of context."
            case .maxTurnRequests: "It hit the limit on tool calls for one turn."
            case .refusal: "It refused."
            case .cancelled: "Stopped."
            }
        }
    }
}

extension ACP.Update: Codable {
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Keys.self)
        let kind = try box.decodeIfPresent(String.self, forKey: .sessionUpdate) ?? ""
        switch kind {
        case "agent_message_chunk":
            self = .message(try ACP.ContentBlock(from: Nested(decoder, "content")))
        case "agent_thought_chunk":
            self = .thought(try ACP.ContentBlock(from: Nested(decoder, "content")))
        case "user_message_chunk":
            self = .userMessage(try ACP.ContentBlock(from: Nested(decoder, "content")))
        case "tool_call", "tool_call_update":
            self = .tool(try ACP.ToolCall(from: decoder))
        case "plan":
            let plan = try decoder.container(keyedBy: Plan.self)
            self = .plan(try plan.decodeIfPresent([ACP.PlanEntry].self, forKey: .entries) ?? [])
        case "usage_update":
            let usage = try decoder.container(keyedBy: Usage.self)
            self = .usage(used: try usage.decodeIfPresent(Int.self, forKey: .used) ?? 0,
                          size: try usage.decodeIfPresent(Int.self, forKey: .size) ?? 0)
        case "available_commands_update":
            let listed = try decoder.container(keyedBy: Commands.self)
            self = .commands(try listed.decodeIfPresent([ACP.Command].self, forKey: .availableCommands) ?? [])
        case "current_mode_update":
            let mode = try decoder.container(keyedBy: Mode.self)
            self = .mode(try mode.decodeIfPresent(String.self, forKey: .currentModeId) ?? "")
        default:
            self = .other(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: Keys.self)
        switch self {
        case .message: try box.encode("agent_message_chunk", forKey: .sessionUpdate)
        case .thought: try box.encode("agent_thought_chunk", forKey: .sessionUpdate)
        case .userMessage: try box.encode("user_message_chunk", forKey: .sessionUpdate)
        case .tool: try box.encode("tool_call", forKey: .sessionUpdate)
        case .plan: try box.encode("plan", forKey: .sessionUpdate)
        case .usage: try box.encode("usage_update", forKey: .sessionUpdate)
        case .commands(let listed):
            try box.encode("available_commands_update", forKey: .sessionUpdate)
            var out = encoder.container(keyedBy: Commands.self)
            try out.encode(listed, forKey: .availableCommands)
        case .mode(let id):
            try box.encode("current_mode_update", forKey: .sessionUpdate)
            var mode = encoder.container(keyedBy: Mode.self)
            try mode.encode(id, forKey: .currentModeId)
        case .other(let kind): try box.encode(kind, forKey: .sessionUpdate)
        }
    }

    enum Plan: String, CodingKey { case entries }
    enum Usage: String, CodingKey { case used, size }
    enum Mode: String, CodingKey { case currentModeId }
    enum Commands: String, CodingKey { case availableCommands }
    enum Content: String, CodingKey { case content }

    /// Reaching one level into the message to decode `content` in place. The alternative
    /// is a wrapper struct per update kind, which is five structs that exist to hold one
    /// field each.
    private struct Nested: Decoder {
        let inner: Decoder
        let key: String
        init(_ inner: Decoder, _ key: String) {
            self.inner = inner
            self.key = key
        }
        var codingPath: [CodingKey] { inner.codingPath }
        var userInfo: [CodingUserInfoKey: Any] { inner.userInfo }
        func container<K: CodingKey>(keyedBy type: K.Type) throws -> KeyedDecodingContainer<K> {
            try inner.container(keyedBy: Content.self)
                .nestedContainer(keyedBy: type, forKey: Content(stringValue: key)!)
        }
        func unkeyedContainer() throws -> UnkeyedDecodingContainer { try inner.unkeyedContainer() }
        func singleValueContainer() throws -> SingleValueDecodingContainer { try inner.singleValueContainer() }
    }
}
