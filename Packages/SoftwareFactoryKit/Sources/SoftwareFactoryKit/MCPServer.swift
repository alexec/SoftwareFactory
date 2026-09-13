import Foundation

/// The factory's MCP server: JSON-RPC 2.0 over stdio, tools only. It owns nothing but
/// the store; the Mac app reads the same folder. `handle(_:)` is a pure function of one
/// request so it can be tested without a process.
///
/// Tool names use underscores because that is the character set every MCP client accepts.
public struct MCPServer: Sendable {
    public let store: FileStore
    public var now: @Sendable () -> Date
    /// How `escalation_await` sleeps between looks at the store.
    public var pollInterval: TimeInterval
    /// A fresh look at the machine, from whoever hosts the server. Nil where it cannot look.
    public var machine: @Sendable () -> MachineReading?
    /// Every tool that waits queues here, so the connections the factory keeps open
    /// are one budget rather than one per tool. (Alex, 12 Sep 2026: harmonised.)
    private let waiters: TaskWaiters

    public static let name = "software-factory"
    public static let version = "0.1.0"
    public static let protocolVersion = "2025-03-26"
    static let maximumWaitingTasks = 20
    /// How long a waiting tool waits before answering "call again", when the caller does
    /// not say. Every waiting tool uses it.
    public static let defaultWaitSeconds = 600

    public init(store: FileStore, now: @escaping @Sendable () -> Date = { .now }, pollInterval: TimeInterval = 1,
                machine: @escaping @Sendable () -> MachineReading? = MCPServer.readMachine) {
        self.store = store
        self.now = now
        self.pollInterval = pollInterval
        self.machine = machine
        waiters = TaskWaiters(limit: Self.maximumWaitingTasks)
    }

    public static let readMachine: @Sendable () -> MachineReading? = {
        #if os(macOS)
        MachineReading.sample()
        #else
        nil
        #endif
    }

    // MARK: The stdio loop

    /// Reads one JSON-RPC message per line from stdin until it closes.
    public func serve() {
        FileHandle.standardError.write(Data("software-factory mcp: store \(store.root.path)\n".utf8))
        var registeredAgentID: String?
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                emit(Self.error(id: nil, code: -32700, message: "Parse error"))
                continue
            }
            if let response = handle(request) {
                if Self.isAgentRegistration(request), let label = Self.registeredAgentLabel(in: response) {
                    registeredAgentID = label
                }
                emit(response)
            }
        }
        if let registeredAgentID {
            do {
                try setConnection(connected: false, for: registeredAgentID)
            } catch {
                FileHandle.standardError.write(Data("software-factory mcp: could not record disconnect: \(error)\n".utf8))
            }
        }
    }

    private func emit(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    // MARK: Dispatch

    /// One request in, one response out. Notifications (no id) return nil.
    public func handle(_ request: [String: Any], agentID: String? = nil) -> [String: Any]? {
        let id = request["id"]
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        let isNotification = id == nil || id is NSNull

        switch method {
        case "initialize":
            return Self.result(id: id, [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": Self.name, "version": Self.version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": Tool.all.map(\.descriptor)])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            var args = params["arguments"] as? [String: Any] ?? [:]
            // The connection's own name, kept apart from the argument so a registration
            // can tell "this is me again" from "I am asking for that name".
            if let agentID {
                args["agent_id"] = agentID
                args["bound_agent_id"] = agentID
            }
            do {
                let text = try call(name, args)
                return Self.result(id: id, ["content": [["type": "text", "text": text]], "isError": false])
            } catch let e as ToolError {
                return Self.result(id: id, ["content": [["type": "text", "text": e.message]], "isError": true])
            } catch {
                return Self.result(id: id, ["content": [["type": "text", "text": "\(error)"]], "isError": true])
            }
        default:
            if isNotification { return nil }
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private final class TaskWaiters: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var waiting: [Waiter] = []

        init(limit: Int) {
            self.limit = limit
        }

        func begin() -> Waiter {
            lock.lock()
            defer { lock.unlock() }
            if waiting.count >= limit, let oldest = waiting.first {
                oldest.reap()
                waiting.removeFirst()
            }
            let waiter = Waiter()
            waiting.append(waiter)
            return waiter
        }

        func end(_ waiter: Waiter) {
            lock.lock()
            defer { lock.unlock() }
            waiting.removeAll { $0 === waiter }
        }

        final class Waiter: @unchecked Sendable {
            private let condition = NSCondition()
            private var reaped = false

            func reap() {
                condition.lock()
                reaped = true
                condition.signal()
                condition.unlock()
            }

            func wait(for interval: TimeInterval) -> Bool {
                condition.lock()
                defer { condition.unlock() }
                guard !reaped else { return true }
                condition.wait(until: Date.now.addingTimeInterval(interval))
                return reaped
            }
        }
    }

    /// The one way a tool waits: poll the store, take a place in the queue, give up
    /// after `timeout_seconds`, and be reaped when the factory needs the connection.
    /// Nil back means it timed out and the caller should say "call again".
    private func waiting<T>(_ tool: String, _ args: [String: Any], for body: () throws -> T?) throws -> T? {
        // Never wait past the hour that marks an agent gone: answer, so the agent calls
        // again and keeps its own heartbeat going.
        let asked = TimeInterval(args["timeout_seconds"] as? Int ?? Self.defaultWaitSeconds)
        let seconds = min(asked, Agent.goneAfter - TimeInterval(Self.defaultWaitSeconds))
        let deadline = now().addingTimeInterval(seconds)
        let waiter = waiters.begin()
        defer { waiters.end(waiter) }
        while true {
            if let found = try body() { return found }
            if now() >= deadline { return nil }
            if waiter.wait(for: pollInterval) {
                throw ToolError(message: "Factory needs this connection for other waiting work. Call \(tool) again in a few minutes.")
            }
        }
    }

    static func result(id: Any?, _ value: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
    }

    static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    public static let instructions = """
        You are working in a software factory. Register first (agent_register), naming the project \
        you work on if you are working one, and keep the id it returns; your MCP session identifies you on every later call, and every call you make is \
        your heartbeat. If you were told to register as a particular name, like A6, pass it as \
        `agent_id`: the app wrote that agent down before it started you, and its card and terminal \
        are already waiting. Without it you are given the next free name instead. If SOFTWARE_FACTORY_SESSION is set in your environment, pass its value as \
        `session` when you register: the app started you and shows your terminal on your page. \
        Work from the \
        backlog: before you create or change a task, call project_read for its project and read its \
        description and instructions. Read the backlog (task_list) and take the work in the order it \
        is in; tasks that belong together sit together, and you may claim several at once when they \
        are one piece of work. task_next hands you the top task nobody is on when you would rather be \
        handed one, and never a parked one — parked is set aside on purpose, not yours to start on \
        your own. Claim what you are on (task_claim) and say when each is done (task_status). If a reply says a project is \
        on hold, finish what you are on and start nothing new on it. When you cannot decide \
        something yourself, raise it \
        (escalation_raise) with two or more \
        options and your recommendation, then wait for the answer (escalation_await). If a task is \
        blocked (waiting on a decision, another task, or a person), mark it (task_block) and pick up \
        the next one (task_next); the factory unblocks it when the wait is over. Before using \
        anything shared (a phone, a simulator, the browser, the whole Mac) lease it (resource_lease) and \
        release it after. Before starting anything heavy, ask the factory (factory_ask): a compile, a \
        simulator, a model. When no work remains, go idle; the factory marks a silent
        agent gone after an hour disconnected and releases its leases. Deregister (agent_deregister)
        only when you are not going to work in the factory again.
        """

    // MARK: Tools

    struct ToolError: Error {
        var message: String
    }

    public struct Tool {
        /// A tool either reads or it writes, and says which. A query never changes the
        /// store, so a client may retry it freely; a command does, and the person's
        /// client can ask before running it. (Alex, 12 Sep 2026.)
        public enum Kind {
            case query
            case command
            /// A command that takes something away: removing a project or a task.
            case destructive
        }

        public var name: String
        public var description: String
        var properties: [String: Any]
        var required: [String]
        var kind: Kind = .command

        /// Every tool takes this, the same way Claude Code's own Bash tool does: a short
        /// line in active voice saying what this particular call is doing ("Claiming
        /// T509", not "task_claim"), so the person reading the transcript sees that
        /// instead of the bare tool name. Not required, and never read by `call`;
        /// display only.
        static var callDescription: [String: Any] {
            str("One line, active voice, what this call is doing right now, e.g. \"Claiming T509\" — shown to the person in place of the tool's name.")
        }

        var descriptor: [String: Any] {
            var properties = properties
            // Project descriptions are actual tool input, so they take precedence over
            // the transcript-only call description used by the other tools.
            if properties["description"] == nil {
                properties["description"] = Self.callDescription
            }
            // The hints a client reads to decide what it may do on its own.
            let annotations: [String: Any] = [
                "readOnlyHint": kind == .query,
                "destructiveHint": kind == .destructive,
                "idempotentHint": kind != .command,
            ]
            return ["name": name, "description": description,
                    "annotations": annotations,
                    "inputSchema": ["type": "object", "properties": properties, "required": required]]
        }

        public static var all: [Tool] { [
            // Agents
            Tool(name: "agent_register", description: "Register this MCP session with the factory. Leave agent_id out and the factory gives you the next A<n>. Every call you make counts as a sign of life; there is no separate check-in. Call again to update this registration.",
                 properties: ["agent_id": str("The name you were told to register as, when you were told one, like A6. Leave it out and the factory gives you the next free name. A name a live session is working as is refused, and so is one that has been used before: a number belongs to one agent for the life of the factory"),
                              "about": str("Optional self-description for other agents"),
                              "project": str("The project you work on, by name: an app, a role across apps, a piece of tooling. Leave it out if your work belongs to no project. A name close to an existing project's is refused; a genuinely new name makes a new project"),
                              "session": str("The value of SOFTWARE_FACTORY_SESSION, when it is set: the terminal session the app started you in, so it can show you working")],
                 required: []),
            Tool(name: "agent_deregister", description: "Leave the factory permanently when you will not work here again. Releases every lease you hold.",
                 properties: [:], required: []),
            Tool(name: "agent_list", description: "Other agents registered with the factory, with their A<n> ids, projects and self-descriptions.",
                 properties: [:], required: [], kind: .query),
            Tool(name: "message_send", description: "Send a message to another agent's inbox.",
                 properties: ["to_agent_id": str("The recipient's id from agent_list"),
                              "subject": str("The message subject"),
                              "contents": str("The message contents")],
                 required: ["to_agent_id", "subject", "contents"]),
            Tool(name: "inbox", description: "Read your inbox. Set wait to hold the call until a message arrives after it begins, and it answers 'no new messages' after timeout_seconds so you can call again.",
                 properties: ["wait": ["type": "boolean", "description": "Wait for a message that arrives after this call begins"],
                              "timeout_seconds": ["type": "integer", "description": "How long to wait, default 600"]],
                 required: [], kind: .query),

            // Projects
            Tool(name: "project_list", description: "Every project, with what is in progress and who is on it.",
                 properties: [:], required: [], kind: .query),
            Tool(name: "project_read", description: "Read one project's name, description and instructions, and record that you have read them. Do this before creating or changing one of its tasks.",
                 properties: ["project": str("Project name or id")], required: ["project"]),
            Tool(name: "project_add", description: "Add a project with a description saying when agents should use it. Instructions are optional guidance agents must read before changing its tasks. A project is a name, not a folder. Returns the project if the name is already taken. A name close to an existing one is refused unless force is set.",
                 properties: ["name": str("The project's name"), "force": ["type": "boolean", "description": "Make it even though the name is close to another project's"],
                              "folder": str("Optional: the folder an agent should run in for this project"),
                              "description": str("A brief description saying when to use this project"),
                              "instructions": str("Optional instructions for agents working this project")],
                 required: ["name", "description"]),
            Tool(name: "project_set", description: "Change a project: its description, its instructions, the folder agents run in, or whether it is on hold. Give only what you are changing; an empty value clears instructions or the folder. A project on hold hands out no work.",
                 properties: ["project": str("Project name"),
                              "set_description": str("A brief description saying when to use this project"),
                              "instructions": str("Instructions agents must read; empty clears them"),
                              "folder": str("The folder an agent runs in; empty clears it"),
                              "on_hold": ["type": "boolean", "description": "True stops work being handed out; false starts it again"]],
                 required: ["project"]),
            Tool(name: "project_remove", description: "Take a project out of the factory: a wrong name, a project that is over. Refused while it has tasks in the backlog, in progress or blocked; move or remove those first. Nothing is deleted: the record stays on disk, out of every list, and its done and parked tasks go with it.",
                 properties: ["project": str("Project name"), "reason": str("Why")],
                 required: ["project"], kind: .destructive),

            // Tasks
            Tool(name: "task_list", description: "A project's backlog in rank order: blocked first, then in progress, the backlog, parked and done. Read this before you work: tasks that belong together sit together. Give task_id for everything about one task, state to see only one kind, or mine to see what is in your name.",
                 properties: ["project": str("Project name"),
                              "task_id": str("One task in full: its whole note, its blockers, and the questions it raised"),
                              "state": ["type": "string", "enum": ["backlog", "inProgress", "done", "parked", "blocked"], "description": "Only tasks in this state"],
                              "mine": ["type": "boolean", "description": "Only tasks in your name"]],
                 required: [], kind: .query),
            Tool(name: "task_next", description: "Hands you the top task nobody is on, or one put in your name, when you would rather be handed one than read the list. Waits until there is one, and answers 'nothing waiting' after timeout_seconds so you can call again. Never hands out a parked task.",
                 properties: ["project": str("Project name"),
                              "timeout_seconds": ["type": "integer", "description": "How long to wait, default 600"]],
                 required: ["project"], kind: .query),
            Tool(name: "task_add", description: "File a task on a project's backlog: at the bottom, at the top, or directly above another task.",
                 properties: ["project": str("Project name"), "title": str("The task, in one line"),
                              "position": ["type": "string", "enum": ["top", "bottom", "parked"], "description": "Defaults to bottom"],
                              "above_task_id": str("Put it directly above this task instead"),
                              "note": str("Why, and anything the next reader needs"),
                              "number": ["type": "integer", "description": "A short number of your choosing (T509), to match a number already in use elsewhere; otherwise the next free one is given"]],
                 required: ["project", "title"]),
            Tool(name: "task_claim", description: "You are on this task now, or on several that are one piece of work. Marks them in progress under your name. Read task_list first: tasks that belong together are usually next to each other.",
                 properties: ["task_id": str("The task"),
                              "task_ids": ["type": "array", "items": ["type": "string"], "description": "Several tasks to take together, when they are one piece of work"]],
                 required: []),
            Tool(name: "task_status", description: "Change a task's state, or several at once: backlog, inProgress, done or parked, with a note on how they ended up.",
                 properties: ["task_id": str("The task"),
                              "task_ids": ["type": "array", "items": ["type": "string"], "description": "Several tasks that ended the same way"],
                              "state": ["type": "string", "enum": ["backlog", "inProgress", "done", "parked"]],
                              "note": str("What happened")],
                 required: ["state"]),
            Tool(name: "task_note", description: "Add a line to a task's note without changing its state: a finding, a question for the person, what you tried. Give several task_ids when one finding belongs on all of them. The line is signed with your name and dated.",
                 properties: ["task_id": str("The task"),
                              "task_ids": ["type": "array", "items": ["type": "string"], "description": "Several tasks the line belongs on"],
                              "text": str("What to add")],
                 required: ["text"]),
            Tool(name: "task_set", description: "Change what a task is rather than where it stands: its title, its number, the project it belongs to, where it sits on the backlog, or whose name is on it. Give only what you are changing.",
                 properties: ["task_id": str("The task"),
                              "title": str("A new title"),
                              "number": ["type": "integer", "description": "A short number (T509), unique across every project"],
                              "project": str("Move it to this project's backlog, at the bottom, with a note saying where it came from"),
                              "above_task_id": str("Put it directly above this task on the same backlog"),
                              "assign_to": str("An agent's A<n> id: the task is theirs, and task_next passes over it for everyone else. Empty takes the name off")],
                 required: ["task_id"]),
            Tool(name: "task_block", description: "This task is blocked: say what it waits on, then move on to the next task. Call it once per thing it waits on; the task clears only when the last one does. A block on a decision or a task clears on its own when the decision lands or the task is done; a block on a person clears when they say so. If the row already waits on a person, a block on a decision replaces that wait: raise the question, then block on it.",
                 properties: ["task_id": str("The task"),
                              "on": ["type": "string", "enum": ["decision", "task", "person", "other"], "description": "What it waits on"],
                              "id": str("The escalation_id or task_id it waits on, for decision or task"),
                              "why": str("In one line, what has to happen")],
                 required: ["task_id", "on", "why"]),
            Tool(name: "task_unblock", description: "Clear one of a blocked task's blockers, by its number (1, 2, …) or a few words from its reason. The task goes back to the backlog when none is left.",
                 properties: ["task_id": str("The task"), "which": str("The blocker's number, or words from its reason")], required: ["task_id", "which"]),
            Tool(name: "task_remove", description: "Take a task off the backlog. Nothing is deleted: the record stays with your reason, out of every list.",
                 properties: ["task_id": str("The task"), "reason": str("Why")], required: ["task_id"], kind: .destructive),

            // Questions
            Tool(name: "escalation_raise", description: "Ask the person to decide something. Give two or more options and say which you recommend. Returns the escalation_id; then call escalation_await. Give task_id when the question stops a task: the task is marked blocked on the decision and unblocks itself when the answer lands.",
                 properties: ["project": str("Project name"), "task_id": str("The task this question stops, if any"),
                              "question": str("The question, in one line"), "context": str("What the person needs to know to choose"),
                              "options": ["type": "array", "minItems": 2, "items": ["type": "object",
                                          "properties": ["title": str("Short name"), "detail": str("What it means")],
                                          "required": ["title"]]],
                              "recommended": ["type": "integer", "description": "Index into options of your recommendation, from 0"]],
                 required: ["project", "question", "options"]),
            Tool(name: "escalation_await", description: "Wait for the person's decision. Returns the chosen option, with any note they added for you, or their answer in their own words when none of the options fit; or 'still open' after timeout_seconds so you can call again.",
                 properties: ["escalation_id": str("From escalation_raise"),
                              "timeout_seconds": ["type": "integer", "description": "How long to wait, default 600"]],
                 required: ["escalation_id"], kind: .query),
            Tool(name: "escalation_list", description: "Open questions, for one project or all.",
                 properties: ["project": str("Project name; omit for all")], required: [], kind: .query),

            // Resources
            Tool(name: "resource_list", description: "Every shared resource: slots, who holds them and until when. Lease one before using a phone, a simulator, the browser or the whole Mac.",
                 properties: [:], required: [], kind: .query),
            Tool(name: "resource_add", description: "Define a shared resource with a number of slots and the longest lease allowed.",
                 properties: ["name": str("e.g. iPhone, Compile, Chrome"), "slots": ["type": "integer", "description": "How many can hold it at once; default 1"],
                              "max_minutes": ["type": "integer", "description": "Longest single lease, in minutes; default 60"], "note": str("What it is")],
                 required: ["name"]),
            Tool(name: "resource_lease", description: "Take one slot for up to some minutes, saying why. Returns the lease and when it runs out, or says the resource is full and when a slot frees. Leasing a resource you already hold renews it, so call this again for more time.",
                 properties: ["resource": str("Resource name or id"),
                              "minutes": ["type": "integer", "description": "How long you need it; capped by the resource's longest lease"], "why": str("What for, in one line")],
                 required: ["resource"]),
            Tool(name: "resource_release", description: "Give a resource back early. Deregistering releases everything you hold.",
                 properties: ["resource": str("Resource name or id")],
                 required: ["resource"]),

            // The Mac itself
            Tool(name: "factory_status", description: "The factory right now: memory, swap, load, compiles and simulators running, the throttle, and the verdict: under, tight or over capacity.",
                 properties: [:], required: [], kind: .query),
            Tool(name: "factory_ask", description: "Ask before starting anything heavy: can I start a compile, a simulator, or a model? Answers yes, wait or no, with the reason. A model is the whole machine.",
                 properties: ["work": ["type": "string", "enum": ["compile", "simulator", "model"]]], required: ["work"], kind: .query),
        ] }

        static func str(_ description: String) -> [String: Any] {
            ["type": "string", "description": description]
        }
    }

    /// What a tool used to be called. A session that loaded the old list keeps working
    /// until it registers again. (Alex, 12 Sep 2026: drop these once nothing calls them.)
    static let oldNames = [
        "agent_messages": "inbox",
        "agent_message_send": "message_send",
        "project_get": "project_read",
        "project_set_description": "project_set",
        "project_set_instructions": "project_set",
        "project_set_path": "project_set",
        "task_show": "task_list",
        "task_number": "task_set",
        "task_rank": "task_set",
        "task_move": "task_set",
        "resource_renew": "resource_lease",
    ]

    func call(_ name: String, _ args: [String: Any]) throws -> String {
        let snap = try store.load()
        var args = args
        var name = name
        if let now = Self.oldNames[name] {
            // The old arguments, in the new shape.
            switch name {
            case "project_set_description": args["set_description"] = args["description"]
            case "project_set_path": args["folder"] = args["path"]
            case "agent_messages": args["wait"] = args["wait_for_new"]
            default: break
            }
            name = now
        }
        // Every call is a sign of life. It happens here, once, so a handler is free to
        // read the caller without writing: a query writes nothing else. (Alex, 12 Sep 2026.)
        if let ref = args["agent_id"] as? String, var caller = agentRef(ref, in: snap), caller.isRegistered {
            caller.lastSeen = now()
            try? store.save(caller)
        }
        switch name {
        case "agent_register":
            let about = args["about"] as? String
            // Most agents work a project; some do not, and that is allowed. Naming one
            // nobody has used makes it. (Alex, 12 Sep 2026: mandatory, then not.)
            var project: Project?
            if let ref = (args["project"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
                project = try resolveProject(ref, in: snap, create: true)
            }
            // The name it was told to use, when it was told one: the app writes an agent
            // down before it starts, and the words it starts with name it. Registering
            // without one asks the factory for the next free number.
            let asked = (args["agent_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var agent: Agent
            if let asked, !asked.isEmpty,
               let claimed = try registering(as: asked, boundTo: args["bound_agent_id"] as? String, in: snap, now: now()) {
                agent = claimed
                agent.deregistered = nil
                agent.lastSeen = now()
                if let about { agent.about = about.trimmingCharacters(in: .whitespacesAndNewlines) }
                if project != nil { agent.projectID = project?.id }
                agent.name = agent.label
            } else {
                let number = try store.takeAgentNumber()
                agent = Agent(number: number, name: "A\(number)",
                              about: about?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                              projectID: project?.id, registered: now())
            }
            // The terminal session the app started it in, when it was started that way.
            // One terminal holds one agent: a shell that outlives its agent keeps
            // SOFTWARE_FACTORY_SESSION exported, so the next one started by hand in that
            // window reports the same session and would bind to the same terminal.
            if let session = (args["session"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !session.isEmpty {
                let claim = Agents.claimSession(session, for: agent, in: snap.agents, now: now())
                agent.session = claim.session
                for released in claim.released { try store.save(released) }
            }
            agent.isConnected = true
            try store.save(agent)
            return "Registered. agent_id: \(agent.label)" + Self.holdWarning(project)

        case "agent_deregister":
            var agent = try agent(args, in: snap)
            agent.deregistered = now()
            try store.save(agent)
            let held = Leases.heldBy(agent.id, in: snap.leases, now: now())
            for var lease in held {
                lease.released = now()
                try store.save(lease)
            }
            return held.isEmpty ? "Deregistered. Thank you." : "Deregistered and released \(held.count) lease\(held.count == 1 ? "" : "s"). Thank you."

        case "agent_list":
            let caller = try agent(args, in: snap)
            let agents = snap.agents.filter { $0.isRegistered && $0.id != caller.id }
            if agents.isEmpty { return "No other agents are registered." }
            // In number order: sorting the labels as text put A10 before A2.
            return agents.sorted { ($0.number ?? .max, $0.label) < ($1.number ?? .max, $1.label) }.map { listed in
                let project = listed.projectID.flatMap { id in snap.projects.first { $0.id == id } }?.name
                let activity = listed.isWorking(now: now()) ? "working" : "quiet"
                let about = listed.about.isEmpty ? "" : "  \(listed.about)"
                return "\(listed.label)  [\(activity)]\(project.map { "  \($0)" } ?? "")\(about)"
            }.joined(separator: "\n")

        case "message_send":
            let sender = try agent(args, in: snap)
            guard let recipient = agentRef(try string("to_agent_id", args), in: snap),
                  recipient.isRegistered
            else { throw ToolError(message: "No active agent has that to_agent_id.") }
            guard recipient.id != sender.id else { throw ToolError(message: "Send messages to another agent, not yourself.") }
            let message = AgentMessage(recipientID: recipient.id, from: sender.label,
                                       subject: try string("subject", args), contents: try string("contents", args), sent: now())
            try store.save(message)
            return "Sent to \(recipient.name)."

        case "inbox":
            let recipient = try agent(args, in: snap)
            let inbox = try store.messages(for: recipient.id)
            guard args["wait"] as? Bool == true else {
                return inbox.isEmpty ? "No messages." : Self.messages(inbox)
            }
            let known = Set(inbox.map(\.id))
            let found = try waiting("inbox", args) { () -> String? in
                let new = try store.messages(for: recipient.id).filter { !known.contains($0.id) }
                return new.isEmpty ? nil : Self.messages(new)
            }
            return found ?? "No new messages. Call inbox again with wait: true."

        case "project_list":
            let dash = Dashboard.make(snapshot: snap, now: now())
            if dash.projects.isEmpty { return "No projects yet." }
            return dash.projects.map { p in
                let doing = p.doing.map { " · \($0)" } ?? ""
                let who = p.agents.map(\.label).joined(separator: ", ")
                let hold = p.project.onHold ? "  ON HOLD" : ""
                let description = p.project.description.isEmpty ? "" : "  \(p.project.description)"
                return "\(p.project.name)\(description)  [\(p.activity.rawValue)\(who.isEmpty ? "" : ": " + who)]\(doing)\(hold)"
            }.joined(separator: "\n")

        case "project_read":
            let project = try resolveProject(try string("project", args), in: snap, create: false)
            var caller = try agent(args, in: snap)
            caller.seenInstructions[project.id] = project.instructions
            try store.save(caller)
            return """
                name: \(project.name)
                description: \(project.description)
                instructions: \(project.instructions.isEmpty ? "(none)" : project.instructions)
                """

        case "project_add":
            let ref = (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (args["path"] as? String) ?? ""
            guard !ref.isEmpty else { throw ToolError(message: "name is required") }
            let name = ref.hasPrefix("/") ? Project.name(fromPath: ref) : ref
            let existing = snap.projects.first { $0.id == ref } ?? Projects.exact(name, in: snap.projects)
            let description = (args["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if existing == nil, description.isEmpty {
                throw ToolError(message: "description is required when creating a project")
            }
            var project = try resolveProject(ref, in: snap, create: true, force: args["force"] as? Bool ?? false,
                                             description: description, instructions: args["instructions"] as? String ?? "")
            if let folder = args["folder"] as? String, !folder.isEmpty, project.path != folder {
                project.path = folder
                try store.save(project)
            }
            return "\(project.name)  \(project.id)"

        case "project_set":
            var project = try resolveProject(try string("project", args), in: snap, create: false)
            var said: [String] = []
            if let description = (args["set_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                project.description = description
                said.append("description is updated")
            }
            if let instructions = (args["instructions"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                project.instructions = instructions
                said.append(instructions.isEmpty ? "instructions are cleared" : "instructions are updated")
            }
            if let folder = args["folder"] as? String {
                project.path = folder.isEmpty ? nil : folder
                said.append(folder.isEmpty ? "has no folder now" : "runs in \(folder)")
            }
            if let onHold = args["on_hold"] as? Bool {
                project.onHold = onHold
                said.append(onHold ? "is on hold: nothing is handed out from its backlog" : "is off hold")
            }
            guard !said.isEmpty else { throw ToolError(message: "Say what to change: set_description, instructions, folder or on_hold.") }
            try store.save(project)
            return "\(project.name) \(said.joined(separator: ", "))."

        case "project_remove":
            var project = try resolveProject(try string("project", args), in: snap, create: false)
            let open = snap.tasks.filter { $0.projectID == project.id && [.backlog, .inProgress, .blocked].contains($0.state) }
            guard open.isEmpty else {
                throw ToolError(message: "\(project.name) still has \(open.count) task\(open.count == 1 ? "" : "s") in the backlog, in progress or blocked. Move them (task_move) or remove them (task_remove) first.")
            }
            project.removed = now()
            try store.save(project)
            let why = (args["reason"] as? String).map { ": \($0)" } ?? ""
            return "Removed \(project.name)\(why). The record is kept, out of the lists."

        case "task_list":
            // One task in full, or a project's backlog, narrowed by state or to your own.
            if let ref = args["task_id"] as? String, !ref.isEmpty {
                guard let task = taskRef(ref, in: snap) else { throw ToolError(message: "No task \(ref).") }
                var lines = [Self.line(task), "note: \(task.note.isEmpty ? "(none)" : task.note)"]
                if let agent = task.agentID.flatMap({ id in snap.agents.first { $0.id == id } }) { lines.append("agent: \(agent.label)") }
                for (n, b) in task.blockers.enumerated() { lines.append("blocker \(n + 1): \(b.kind.rawValue)\(b.id.map { " \($0.uuidString)" } ?? ""): \(b.why)") }
                for e in snap.escalations where e.taskID == task.id {
                    let answer = e.answer.map { "→ \($0), by \(e.decision?.by ?? "someone")" } ?? "open"
                    lines.append("question \(e.id.uuidString): \(e.question) \(answer)")
                }
                return lines.joined(separator: "\n")
            }
            let project = try resolveProject(try string("project", args), in: snap, create: false)
            var tasks = Backlog.tasks(for: project.id, in: snap.tasks)
            if let wanted = (args["state"] as? String).flatMap(FactoryTask.State.init(rawValue:)) {
                tasks = tasks.filter { $0.state == wanted }
            }
            if args["mine"] as? Bool == true {
                let caller = try? agent(args, in: snap)
                tasks = tasks.filter { $0.agentID == caller?.id }
            }
            let hold = project.onHold ? Self.holdWarning(project).dropFirst() + "\n" : ""
            if tasks.isEmpty { return hold + "Nothing on the backlog." }
            return hold + tasks.map(Self.line).joined(separator: "\n")

        case "task_next":
            let project = try resolveProject(try string("project", args), in: snap, create: false)
            // Anything in this agent's name comes first; anything in someone else's is
            // passed over.
            let caller = try? agent(args, in: snap)
            let found = try waiting("task_next", args) { () -> String? in
                let current = try store.load()
                guard let t = Backlog.next(for: project.id, in: current.tasks, agentID: caller?.id) else { return nil }
                let currentProject = current.projects.first { $0.id == project.id } ?? project
                return Self.line(t) + Self.noteBlock(t) + Self.holdWarning(currentProject)
            }
            return found ?? "Nothing waiting. Call task_next again."

        case "task_add":
            let project = try resolveProject(try string("project", args), in: snap, create: false)
            try requireProjectRead(project, args: args, in: snap)
            let position = (args["position"] as? String).flatMap(Backlog.Position.init(rawValue:)) ?? .bottom
            let every = (try? store.loadEveryTask()) ?? snap.tasks
            var number = Backlog.nextNumber(in: every)
            if let wanted = args["number"] as? Int {
                if let taken = every.first(where: { $0.number == wanted }) { throw ToolError(message: "T\(wanted) is already \(taken.title).") }
                number = wanted
            }
            var task = FactoryTask(number: number, projectID: project.id, title: try string("title", args),
                                   state: Backlog.state(for: position),
                                   rank: Backlog.rank(for: position, projectID: project.id, in: snap.tasks),
                                   note: args["note"] as? String ?? "", created: now())
            if let aboveRef = args["above_task_id"] as? String, !aboveRef.isEmpty {
                guard let above = taskRef(aboveRef, in: snap), above.projectID == project.id
                else { throw ToolError(message: "above_task_id is not a task on that backlog") }
                task.rank = above.rank
                for moved in Backlog.place(task, above: above, in: snap.tasks.filter { $0.projectID == project.id } + [task], at: now()) {
                    if moved.id == task.id { task = moved } else { try store.save(moved) }
                }
            }
            try store.save(task)
            return "Filed. task_id: \(task.id.uuidString), T\(number)"

        case "task_set":
            var task = try task(args, in: snap)
            try requireProjectRead(for: task, args: args, in: snap)
            var said: [String] = []
            if let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                task.title = title
                said.append("is now called \(title)")
            }
            if let wanted = args["number"] as? Int {
                guard wanted > 0 else { throw ToolError(message: "number must be a whole number above 0") }
                let every = (try? store.loadEveryTask()) ?? snap.tasks
                if let taken = every.first(where: { $0.number == wanted && $0.id != task.id }) { throw ToolError(message: "T\(wanted) is already \(taken.title).") }
                task.number = wanted
                said.append("is T\(wanted)")
            }
            if let who = args["assign_to"] as? String {
                let agent = who.isEmpty ? nil : agentRef(who, in: snap)
                if !who.isEmpty, agent == nil { throw ToolError(message: "No agent \(who).") }
                task = Backlog.assign(task, to: agent?.id, named: agent?.label, by: try self.agent(args, in: snap).label, at: now())
                said.append(agent.map { "is \($0.label)'s" } ?? "is nobody's")
            }
            if let ref = args["above_task_id"] as? String, !ref.isEmpty {
                guard let other = taskRef(ref, in: snap), other.projectID == task.projectID
                else { throw ToolError(message: "above_task_id is not a task on the same backlog") }
                // The rank place() gives this task has to survive the save at the end.
                let siblings = snap.tasks.filter { $0.projectID == task.projectID && $0.id != task.id } + [task]
                let changed = Backlog.place(task, above: other, in: siblings, at: now())
                for t in changed where t.id != task.id { try store.save(t) }
                if let moved = changed.first(where: { $0.id == task.id }) { task = moved }
                said.append("now sits above \(other.title)")
            }
            if let ref = args["project"] as? String, !ref.isEmpty {
                let project = try resolveProject(ref, in: snap, create: false)
                try requireProjectRead(project, args: args, in: snap)
                guard project.id != task.projectID else { throw ToolError(message: "\(task.title) is already on \(project.name).") }
                task = Backlog.move(task, to: project, from: snap.projects.first { $0.id == task.projectID }, in: snap.tasks, at: now())
                said.append("is on \(project.name)'s backlog")
            }
            guard !said.isEmpty else { throw ToolError(message: "Say what to change: title, number, project, above_task_id or assign_to.") }
            task.updated = now()
            try store.save(task)
            return "\(task.title) \(said.joined(separator: ", "))."

        case "task_claim":
            // One task, or several that are one piece of work: an agent that has read the
            // backlog can see what belongs together. (Alex, 12 Sep 2026.)
            var refs = (args["task_ids"] as? [String]) ?? []
            if let one = args["task_id"] as? String, !one.isEmpty { refs.insert(one, at: 0) }
            guard !refs.isEmpty else { throw ToolError(message: "task_id or task_ids is required") }
            var agent = try agent(args, in: snap)
            var claimed: [FactoryTask] = []
            for ref in refs {
                guard let task = taskRef(ref, in: snap) else { throw ToolError(message: "No task \(ref).") }
                try requireProjectRead(for: task, agent: agent, in: snap)
                try store.save(Backlog.set(task, to: .inProgress, agentID: agent.id, at: now()))
                claimed.append(task)
            }
            agent.taskID = claimed.first?.id
            agent.note = claimed.map(\.title).joined(separator: "; ")
            agent.lastSeen = now()
            try store.save(agent)
            let titles = claimed.map(\.title).joined(separator: "\n  ")
            let notes = claimed.count == 1 ? Self.noteBlock(claimed[0]) : ""
            return "You are on: \(claimed.count == 1 ? titles : "\n  " + titles)" + notes
                + Self.holdWarning(snap.projects.first { $0.id == claimed[0].projectID })

        case "task_status":
            var task = try task(args, in: snap)
            try requireProjectRead(for: task, args: args, in: snap)
            guard let state = FactoryTask.State(rawValue: try string("state", args)) else {
                throw ToolError(message: "state must be backlog, inProgress, done or parked")
            }
            if let note = args["note"] as? String, !note.isEmpty {
                task.note = task.note.isEmpty ? note : task.note + "\n" + note
            }
            try store.save(Backlog.set(task, to: state, at: now()))
            guard state == .done, let agentID = task.agentID else {
                return "\(task.title): \(state.rawValue)"
            }
            if var agent = snap.agents.first(where: { $0.id == agentID }), agent.taskID == task.id {
                agent.taskID = nil
                try store.save(agent)
            }
            let hasOtherAssignment = snap.tasks.contains {
                $0.id != task.id && $0.agentID == agentID && $0.state == .inProgress
            }
            guard !hasOtherAssignment,
                  let next = Backlog.next(for: task.projectID, in: snap.tasks.filter { $0.id != task.id })
            else {
                return "\(task.title): done"
            }
            return "\(task.title): done\nNext on the backlog: \(Self.line(next))\nYou should work on this next."

        case "task_note":
            let task = try task(args, in: snap)
            try requireProjectRead(for: task, args: args, in: snap)
            let who = try agent(args, in: snap).label
            let noted = Backlog.comment(on: task, try string("text", args), by: who, at: now())
            try store.save(noted)
            return "Noted on \(task.title)."

        case "task_block":
            let task = try task(args, in: snap)
            try requireProjectRead(for: task, args: args, in: snap)
            guard let kind = FactoryTask.Blocker.Kind(rawValue: try string("on", args)) else {
                throw ToolError(message: "on must be decision, task, person or other")
            }
            let id = (args["id"] as? String).flatMap(UUID.init(uuidString:))
            if kind == .decision || kind == .task, id == nil { throw ToolError(message: "id is needed for a block on a \(kind.rawValue)") }
            let blocked = Backlog.block(task, on: .init(kind: kind, id: id, why: try string("why", args)), at: now())
            try store.save(blocked)
            let next = Backlog.next(for: task.projectID, in: snap.tasks.filter { $0.id != task.id }).map { " Next on the backlog: \($0.title) (\($0.id.uuidString))." } ?? " Nothing else is waiting on this backlog."
            let count = blocked.blockers.count
            let replaced = task.blockers.contains { $0.kind == .person } && !blocked.blockers.contains { $0.kind == .person }
                ? " The decision replaces the wait on a person: same gate, and this one clears itself when the answer lands." : ""
            return "\(task.title) is blocked on \(count) thing\(count == 1 ? "" : "s").\(replaced)\(next)"

        case "task_remove":
            let task = try task(args, in: snap)
            try store.save(Backlog.remove(task, why: args["reason"] as? String ?? "", at: now()))
            return "Removed: \(task.title). The record is kept, out of the lists."

        case "task_unblock":
            let task = try task(args, in: snap)
            try requireProjectRead(for: task, args: args, in: snap)
            guard task.state == .blocked else { throw ToolError(message: "\(task.title) is not blocked.") }
            do {
                let cleared = try Backlog.unblock(task, matching: try string("which", args), at: now())
                try store.save(cleared)
                return cleared.state == .blocked
                    ? "Cleared one. \(task.title) still waits on \(cleared.blockers.count): \(cleared.blockedWhy)"
                    : "Cleared the last one. \(task.title) is back on the backlog."
            } catch Backlog.UnblockError.noMatch {
                throw ToolError(message: "No blocker matches. They are: " + task.blockers.enumerated().map { "\($0 + 1). \($1.why)" }.joined(separator: "; "))
            } catch Backlog.UnblockError.ambiguous {
                throw ToolError(message: "More than one blocker matches; give its number: " + task.blockers.enumerated().map { "\($0 + 1). \($1.why)" }.joined(separator: "; "))
            }

        case "escalation_raise":
            let project = try resolveProject(try string("project", args), in: snap, create: true)
            guard let raw = args["options"] as? [[String: Any]], raw.count >= 2 else {
                throw ToolError(message: "options needs at least two entries")
            }
            let recommended = args["recommended"] as? Int ?? 0
            let options = raw.enumerated().map { i, o in
                Escalation.Option(title: o["title"] as? String ?? "Option \(i + 1)",
                                  detail: o["detail"] as? String ?? "", recommended: i == recommended)
            }
            var agent: Agent?
            if args["agent_id"] != nil { agent = try self.agent(args, in: snap) }
            var task: FactoryTask?
            if let ref = args["task_id"] as? String, !ref.isEmpty { task = try self.task(args, in: snap) }
            if let task { try requireProjectRead(for: task, args: args, in: snap) }
            let escalation = Escalation(
                projectID: project.id, question: try string("question", args),
                context: args["context"] as? String ?? "", options: options,
                agentID: agent?.id, taskID: task?.id, raisedBy: agent?.label ?? "agent", raised: now())
            try store.save(escalation)
            if let task {
                try store.save(Backlog.block(task, on: .init(kind: .decision, id: escalation.id, why: escalation.question), at: now()))
                return "Raised. escalation_id: \(escalation.id.uuidString). \(task.title) is blocked on it and unblocks when the answer lands; pick up task_next meanwhile, or call escalation_await."
            }
            return "Raised. escalation_id: \(escalation.id.uuidString). Now call escalation_await."

        case "escalation_await":
            guard let id = UUID(uuidString: try string("escalation_id", args)) else {
                throw ToolError(message: "escalation_id is not an id")
            }
            let found = try waiting("escalation_await", args) { () -> String? in
                guard let e = store.escalation(id) else { throw ToolError(message: "No escalation \(id.uuidString)") }
                guard let d = e.decision else { return nil }
                if let chosen = e.chosen {
                    let detail = chosen.detail.isEmpty ? "" : " (\(chosen.detail))"
                    let note = d.note.isEmpty ? "" : "\nNote from \(d.by): \(d.note)"
                    return "Decided by \(d.by): \(chosen.title)\(detail)\(note)"
                }
                return "Answered by \(d.by) in their own words, none of the options: \(d.note)"
            }
            return found ?? "Still open. Call escalation_await again."

        case "escalation_list":
            var open = snap.escalations.filter(\.isOpen)
            if let ref = args["project"] as? String, !ref.isEmpty {
                let project = try resolveProject(ref, in: snap, create: false)
                open = open.filter { $0.projectID == project.id }
            }
            if open.isEmpty { return "Nothing open." }
            return open.map { e in
                let project = snap.projects.first { $0.id == e.projectID }?.name ?? e.projectID
                let opts = e.options.map { "\($0.title)\($0.recommended ? " (recommended)" : "")" }.joined(separator: " | ")
                let stops = e.taskID.flatMap { id in snap.tasks.first { $0.id == id } }.map { "  stops: \($0.title)" } ?? ""
                return "\(e.id.uuidString)  [\(project)] \(e.question)  \(opts)\(stops)"
            }.joined(separator: "\n")

        case "resource_list":
            if snap.resources.isEmpty { return "No resources defined. resource_add makes one." }
            return snap.resources.sorted { $0.name < $1.name }.map { r in
                let held = Leases.held(for: r.id, in: snap.leases, agents: snap.agents, now: now())
                let free = r.slots - held.count
                let holders = held.map { l in
                    let who = snap.agents.first { $0.id == l.agentID }?.label ?? "someone"
                    let when = l.until <= now() ? "OVERDUE since \(Self.clock(l.until))" : "until \(Self.clock(l.until))"
                    return "\(who) \(when)\(l.why.isEmpty ? "" : " (\(l.why))")"
                }.joined(separator: ", ")
                return "\(r.name)  \(free) of \(r.slots) free  max \(Int(r.maxLease / 60)) min\(holders.isEmpty ? "" : "  held by \(holders)")"
            }.joined(separator: "\n")

        case "resource_add":
            let name = try string("name", args)
            if let existing = snap.resources.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return "Already defined: \(existing.name), \(existing.slots) slot\(existing.slots == 1 ? "" : "s")."
            }
            let resource = Resource(name: name, slots: args["slots"] as? Int ?? 1,
                                    maxLease: TimeInterval((args["max_minutes"] as? Int ?? 60) * 60),
                                    note: args["note"] as? String ?? "", created: now())
            try store.save(resource)
            return "Defined \(resource.name): \(resource.slots) slot\(resource.slots == 1 ? "" : "s"), leases up to \(Int(resource.maxLease / 60)) min."

        case "resource_lease":
            let agent = try agent(args, in: snap)
            let resource = try resource(args, in: snap)
            let minutes = TimeInterval(args["minutes"] as? Int ?? Int(resource.maxLease / 60))
            switch Leases.lease(resource, for: agent.id, wanting: minutes * 60, why: args["why"] as? String ?? "", in: snap.leases, agents: snap.agents, now: now()) {
            case .leased(let lease):
                try store.save(lease)
                return "Leased \(resource.name) until \(Self.clock(lease.until)). Renew it (resource_renew) if the job runs long; release it when you are done."
            case .full(let nextFree, let held):
                let who = held.map { l in
                    let name = snap.agents.first { $0.id == l.agentID }?.label ?? "someone"
                    return l.until <= now() ? "\(name), overdue since \(Self.clock(l.until)) and still registered" : name
                }.joined(separator: ", ")
                let frees = nextFree > now() ? "A slot frees at \(Self.clock(nextFree))." : "No slot has a known end: the holder's job outlived its lease."
                return "\(resource.name) is full (held by \(who)). \(frees) Do something else and ask again."
            }

        case "resource_release":
            let agent = try agent(args, in: snap)
            let resource = try resource(args, in: snap)
            guard let mine = Leases.held(for: resource.id, in: snap.leases, agents: snap.agents, now: now()).first(where: { $0.agentID == agent.id }) else {
                return "You were not holding \(resource.name)."
            }
            try store.save(try Leases.release(mine, for: agent.id, now: now()))
            return "Released \(resource.name)."

        case "factory_status":
            guard let r = machine() else { throw ToolError(message: "This server cannot see the machine.") }
            let t = store.throttle()
            let verdict = Capacity.verdict(r, throttle: t)
            return """
                \(verdict.rawValue.capitalized) capacity. \(Capacity.reason(r, throttle: t))
                Memory \(Capacity.percent(r.memoryFreeFraction)) free of \(Capacity.gigabytes(r.memoryTotal)); swap \(Capacity.gigabytes(r.swapUsed)) of \(Capacity.gigabytes(r.swapTotal)); load \(String(format: "%.1f", r.load)) on \(r.cores) cores.
                Compiles \(r.compiles) of \(t.compileSlots); simulators \(r.simulators) of \(t.simulatorSlots). Nothing new starts above \(Capacity.percent(t.swapCeiling)) swap or below \(Capacity.percent(t.memoryFloor)) free.
                """

        case "factory_ask":
            guard let work = Capacity.Work(rawValue: try string("work", args)) else { throw ToolError(message: "work must be compile, simulator or model") }
            guard let r = machine() else { throw ToolError(message: "This server cannot see the machine.") }
            return Capacity.ask(work, r, throttle: store.throttle()).text

        case "agent_checkin":
            // Gone since 12 September 2026, but a session that loaded the tool list before
            // then still has it. Its call counts as the heartbeat it wanted to send.
            _ = try agent(args, in: snap)
            return "Noted. There is no check-in any more: every call you make counts as one, so carry on."

        default:
            throw ToolError(message: "Unknown tool: \(name)")
        }
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    func resource(_ args: [String: Any], in snap: Snapshot) throws -> Resource {
        let ref = try string("resource", args)
        if let id = UUID(uuidString: ref), let r = snap.resources.first(where: { $0.id == id }) { return r }
        if let r = snap.resources.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) { return r }
        throw ToolError(message: "No resource called \(ref). Known: \(snap.resources.map(\.name).joined(separator: ", "))")
    }

    // MARK: Helpers

    /// The whole note, for the agent that is about to act on the task. (Alex, 12 Sep 2026:
    /// add the note to the agent's message.)
    static func noteBlock(_ t: FactoryTask) -> String {
        t.note.isEmpty ? "" : "\nnote: \(t.note)"
    }

    static func line(_ t: FactoryTask) -> String {
        let blocked = t.blockers.isEmpty ? "" : "  [blocked on " + t.blockers.map { "\($0.kind.rawValue): \($0.why)" }.joined(separator: "; ") + "]"
        let last = t.note.split(whereSeparator: \.isNewline).last.map { "  — \($0)" } ?? ""
        return "\(t.label ?? "T-")  \(t.id.uuidString)  \(t.state.rawValue)  \(t.title)\(blocked)\(last)"
    }

    static func messages(_ messages: [AgentMessage]) -> String {
        messages.map {
            "\($0.id.uuidString)\nfrom: \($0.from)\nsubject: \($0.subject)\ncontents:\n\($0.contents)"
        }.joined(separator: "\n\n")
    }

    func string(_ key: String, _ args: [String: Any]) throws -> String {
        guard let v = args[key] as? String, !v.isEmpty else { throw ToolError(message: "\(key) is required") }
        return v
    }

    /// Resolves the caller. Reading only: the heartbeat is stamped once per call, at
    /// the top of `call`.
    func agent(_ args: [String: Any], in snap: Snapshot) throws -> Agent {
        guard let agent = agentRef(try string("agent_id", args), in: snap)
        else { throw ToolError(message: "Unknown agent_id. Call agent_register first.") }
        return agent
    }

    func agentRef(_ ref: String, in snap: Snapshot) -> Agent? {
        if let id = UUID(uuidString: ref), let agent = snap.agents.first(where: { $0.id == id }) {
            return agent
        }
        guard ref.first == "A", let number = Int(ref.dropFirst()) else { return nil }
        return snap.agents.first { $0.number == number }
    }

    static func nextAgentNumber(in agents: [Agent]) -> Int { Agents.nextNumber(in: agents) }

    /// The agent a registration is for, when it asked for one by name.
    ///
    /// It gets the record if the name is its own: an agent the app wrote down before it
    /// started, or one coming back after its connection dropped. It is refused while
    /// another session is live on that name, and refused a number that has been given
    /// out before, because a number means one agent for the life of the factory. A
    /// number nobody has had yet is its own for the asking.
    func registering(as ref: String, boundTo bound: String?, in snap: Snapshot, now: Date) throws -> Agent? {
        if let existing = agentRef(ref, in: snap) {
            // Its own name, on a connection already registered as it: this is the same
            // agent calling again to change what it says about itself.
            let itsOwn = bound.flatMap { agentRef($0, in: snap) }?.id == existing.id
            // A name is taken while a session is live on it. A session that died hard
            // never says goodbye, so ten minutes of silence gives the name back.
            guard itsOwn || !existing.hasLiveSession(now: now) else {
                throw ToolError(message: "\(existing.label) is taken: a session is working as it. Register with no agent_id and the factory will give you a name of your own.")
            }
            var agent = existing
            // A record written before the counter existed spends its number now.
            if let number = agent.number {
                try store.agentNumbers().claim(number)
            } else {
                agent.number = try store.takeAgentNumber()
            }
            return agent
        }
        // Anything that is not a name at all is nothing to go on: the factory names it.
        guard ref.first == "A", let number = Int(ref.dropFirst()), number > 0 else { return nil }
        // Free only if nobody has ever had it: a deleted agent does not give its name back.
        guard try store.agentNumbers().claim(number) else {
            throw ToolError(message: "A\(number) has been given out before, and a number belongs to one agent for good. Register with no agent_id and the factory will give you the next one.")
        }
        return Agent(number: number, name: "A\(number)", projectID: nil, registered: now)
    }

    func setConnection(connected: Bool, for agentID: String) throws {
        let snap = try store.load()
        guard var agent = agentRef(agentID, in: snap) else {
            throw ToolError(message: "Unknown agent_id. Call agent_register first.")
        }
        let timestamp = now()
        agent.isConnected = connected
        agent.lastSeen = timestamp
        try store.save(agent)
    }

    static func isAgentRegistration(_ request: [String: Any]) -> Bool {
        let params = request["params"] as? [String: Any]
        return request["method"] as? String == "tools/call" && params?["name"] as? String == "agent_register"
    }

    static func registeredAgentLabel(in response: [String: Any]) -> String? {
        guard let result = response["result"] as? [String: Any],
              result["isError"] as? Bool == false,
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let label = text.split(whereSeparator: \.isWhitespace).first(where: {
                  $0.first == "A" && Int($0.dropFirst()) != nil
              })
        else { return nil }
        return String(label)
    }

    /// A task by its id, or by its number as "T509" or "509".
    func task(_ args: [String: Any], in snap: Snapshot) throws -> FactoryTask {
        let ref = try string("task_id", args)
        guard let task = taskRef(ref, in: snap) else {
            throw ToolError(message: "Unknown task_id: \(ref). A task's UUID, or its number as T509.")
        }
        return task
    }

    func taskRef(_ ref: String, in snap: Snapshot) -> FactoryTask? {
        if let id = UUID(uuidString: ref), let task = snap.tasks.first(where: { $0.id == id }) { return task }
        return Backlog.task(numbered: ref, in: snap.tasks)
    }

    /// A project by name (case does not matter) or id. An old caller may still send a
    /// folder path: that means the folder's name, and matches a project registered under
    /// that path before names stood alone. An unknown name becomes a project when
    /// `create` is set, so an agent can file against its project without a step first.
    func resolveProject(_ ref: String, in snap: Snapshot, create: Bool, force: Bool = false,
                        description: String = "", instructions: String = "") throws -> Project {
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ref.hasPrefix("/") ? Project.name(fromPath: ref) : ref
        if let p = snap.projects.first(where: { $0.id == ref }) { return p }
        if let p = Projects.exact(name, in: snap.projects) { return p }
        guard create, !name.isEmpty else {
            throw ToolError(message: "No project called \(name). Known: \(snap.projects.map(\.name).joined(separator: ", "))")
        }
        // A near miss is a slip, not a new project. (Director, 12 Sep 2026.)
        if !force, let near = Projects.nearMiss(name, in: snap.projects) {
            throw ToolError(message: "No project called \(name), but there is \(near.name): use that name. If \(name) really is a different project, project_add it with force.")
        }
        let p = Project(name: name, description: description, instructions: instructions, added: now())
        try store.save(p)
        return p
    }

    /// Registered agents must explicitly read the project's current instructions before
    /// a task-changing command. Calls without a registered agent preserve the CLI's
    /// local administrative use.
    func requireProjectRead(_ project: Project, args: [String: Any], in snap: Snapshot) throws {
        guard let ref = args["agent_id"] as? String,
              let agent = agentRef(ref, in: snap),
              agent.isRegistered
        else { return }
        try requireProjectRead(project, agent: agent, in: snap)
    }

    func requireProjectRead(for task: FactoryTask, args: [String: Any], in snap: Snapshot) throws {
        guard let project = snap.projects.first(where: { $0.id == task.projectID }) else {
            throw ToolError(message: "The project for \(task.title) no longer exists.")
        }
        try requireProjectRead(project, args: args, in: snap)
    }

    func requireProjectRead(for task: FactoryTask, agent: Agent, in snap: Snapshot) throws {
        guard let project = snap.projects.first(where: { $0.id == task.projectID }) else {
            throw ToolError(message: "The project for \(task.title) no longer exists.")
        }
        try requireProjectRead(project, agent: agent, in: snap)
    }

    func requireProjectRead(_ project: Project, agent: Agent, in _: Snapshot) throws {
        guard agent.seenInstructions[project.id] == project.instructions else {
            throw ToolError(message: "You must first call project_get for \(project.name) and read its instructions before creating or modifying a task.")
        }
    }

    static func holdWarning(_ project: Project?) -> String {
        guard let project, project.onHold else { return "" }
        return "\nWARNING: \(project.name) is on hold. Do not start any new tasks on it; finish what you are on, then go idle."
    }
}
