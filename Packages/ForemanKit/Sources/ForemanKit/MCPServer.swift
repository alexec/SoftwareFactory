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

    public static let name = "foreman"
    public static let version = "0.1.0"
    public static let protocolVersion = "2025-06-18"

    public init(store: FileStore, now: @escaping @Sendable () -> Date = { .now }, pollInterval: TimeInterval = 1) {
        self.store = store
        self.now = now
        self.pollInterval = pollInterval
    }

    // MARK: The stdio loop

    /// Reads one JSON-RPC message per line from stdin until it closes.
    public func serve() {
        FileHandle.standardError.write(Data("foreman mcp: store \(store.root.path)\n".utf8))
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                emit(Self.error(id: nil, code: -32700, message: "Parse error"))
                continue
            }
            if let response = handle(request) { emit(response) }
        }
    }

    private func emit(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    // MARK: Dispatch

    /// One request in, one response out. Notifications (no id) return nil.
    public func handle(_ request: [String: Any]) -> [String: Any]? {
        let id = request["id"]
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        let isNotification = id == nil || id is NSNull

        switch method {
        case "initialize":
            return Self.result(id: id, [
                "protocolVersion": (params["protocolVersion"] as? String) ?? Self.protocolVersion,
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
            let args = params["arguments"] as? [String: Any] ?? [:]
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

    static func result(id: Any?, _ value: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
    }

    static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    public static let instructions = """
        You are working in a software factory. Register first (agent_register) and keep the id it \
        returns; pass it to every other call. Check in (agent_checkin) every few minutes with what you \
        are on. When you cannot decide something yourself, raise it (escalation_raise) with two or more \
        options and your recommendation, then wait for the answer (escalation_await). Deregister \
        (agent_deregister) when you are finished.
        """

    // MARK: Tools

    struct ToolError: Error {
        var message: String
    }

    public struct Tool {
        public var name: String
        public var description: String
        var properties: [String: Any]
        var required: [String]

        var descriptor: [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required]]
        }

        public static var all: [Tool] { [
            Tool(name: "agent_register", description: "Register with the factory. Returns your agent_id; pass it to every other call.",
                 properties: ["name": str("Your name, e.g. packed-lead or agent-3"),
                              "project": str("The project's folder path")],
                 required: ["name"]),
            Tool(name: "agent_checkin", description: "Say what you are on. Call it every few minutes; the floor shows an agent as quiet after two minutes without one.",
                 properties: ["agent_id": str("From agent_register"), "task_id": str("The task you are on, if any"),
                              "note": str("One line on what you are doing")],
                 required: ["agent_id"]),
            Tool(name: "agent_deregister", description: "You are finished. Call this as your last action.",
                 properties: ["agent_id": str("From agent_register")], required: ["agent_id"]),

            Tool(name: "project_list", description: "Every project, with what is in progress and who is on it.",
                 properties: [:], required: []),
            Tool(name: "project_add", description: "Make a folder a project, or rename one.",
                 properties: ["path": str("Absolute folder path"), "name": str("Display name; defaults to the folder name")],
                 required: ["path"]),

            Tool(name: "task_list", description: "A project's backlog in rank order: in progress first, then backlog, then done.",
                 properties: ["project": str("Folder path or project name")], required: ["project"]),
            Tool(name: "task_next", description: "The top task on a project's backlog that nobody is on.",
                 properties: ["project": str("Folder path or project name")], required: ["project"]),
            Tool(name: "task_add", description: "File a task at the end of a project's backlog.",
                 properties: ["project": str("Folder path or project name"), "title": str("The task, in one line"),
                              "kind": ["type": "string", "enum": ["feature", "bug", "chore"], "description": "Defaults to feature"],
                              "note": str("Why, and anything the next reader needs")],
                 required: ["project", "title"]),
            Tool(name: "task_claim", description: "You are on this task now. Marks it in progress under your name.",
                 properties: ["task_id": str("The task"), "agent_id": str("From agent_register")], required: ["task_id", "agent_id"]),
            Tool(name: "task_status", description: "Change a task's state: backlog, inProgress or done, with a note on how it ended up.",
                 properties: ["task_id": str("The task"),
                              "state": ["type": "string", "enum": ["backlog", "inProgress", "done"]],
                              "note": str("What happened")],
                 required: ["task_id", "state"]),
            Tool(name: "task_rank", description: "Move a task directly above another on the same backlog.",
                 properties: ["task_id": str("The task to move"), "above_task_id": str("The task it should sit above")],
                 required: ["task_id", "above_task_id"]),
            Tool(name: "task_remove", description: "Take a task off the backlog for good.",
                 properties: ["task_id": str("The task"), "reason": str("Why")], required: ["task_id"]),

            Tool(name: "escalation_raise", description: "Ask the person to decide something. Give two or more options and say which you recommend. Returns the escalation_id; then call escalation_await.",
                 properties: ["agent_id": str("From agent_register"), "project": str("Folder path or project name"),
                              "question": str("The question, in one line"), "context": str("What the person needs to know to choose"),
                              "options": ["type": "array", "minItems": 2, "items": ["type": "object",
                                          "properties": ["title": str("Short name"), "detail": str("What it means")],
                                          "required": ["title"]]],
                              "recommended": ["type": "integer", "description": "Index into options of your recommendation, from 0"]],
                 required: ["project", "question", "options"]),
            Tool(name: "escalation_await", description: "Wait for the person's decision. Returns the chosen option, or 'still open' after timeout_seconds so you can call again.",
                 properties: ["escalation_id": str("From escalation_raise"),
                              "timeout_seconds": ["type": "integer", "description": "How long to wait, default 600"]],
                 required: ["escalation_id"]),
            Tool(name: "escalation_list", description: "Open questions, for one project or all.",
                 properties: ["project": str("Folder path or project name; omit for all")], required: []),
        ] }

        static func str(_ description: String) -> [String: Any] {
            ["type": "string", "description": description]
        }
    }

    func call(_ name: String, _ args: [String: Any]) throws -> String {
        let snap = try store.load()
        switch name {
        case "agent_register":
            let agentName = try string("name", args)
            var project: Project?
            if let ref = args["project"] as? String, !ref.isEmpty { project = try resolveProject(ref, in: snap, create: true) }
            let agent = Agent(name: agentName, projectID: project?.id, registered: now())
            try store.save(agent)
            return "Registered. agent_id: \(agent.id.uuidString)"

        case "agent_checkin":
            var agent = try agent(args, in: snap)
            agent.lastSeen = now()
            if let t = args["task_id"] as? String, let id = UUID(uuidString: t) { agent.taskID = id }
            if let note = args["note"] as? String { agent.note = note }
            try store.save(agent)
            return "Checked in."

        case "agent_deregister":
            var agent = try agent(args, in: snap)
            agent.deregistered = now()
            try store.save(agent)
            return "Deregistered. Thank you."

        case "project_list":
            let dash = Dashboard.make(snapshot: snap, now: now())
            if dash.projects.isEmpty { return "No projects yet." }
            return dash.projects.map { p in
                let doing = p.doing.map { " · \($0)" } ?? ""
                let who = p.agents.map(\.name).joined(separator: ", ")
                return "\(p.project.name)  \(p.project.path)  [\(p.activity.rawValue)\(who.isEmpty ? "" : ": " + who)]\(doing)"
            }.joined(separator: "\n")

        case "project_add":
            let path = try string("path", args)
            var project = try resolveProject(path, in: snap, create: true)
            if let n = args["name"] as? String, !n.isEmpty { project.name = n; try store.save(project) }
            return "\(project.name)  \(project.path)"

        case "task_list":
            let project = try resolveProject(try string("project", args), in: snap, create: false)
            let tasks = Backlog.tasks(for: project.id, in: snap.tasks)
            if tasks.isEmpty { return "Nothing on the backlog." }
            return tasks.map(Self.line).joined(separator: "\n")

        case "task_next":
            let project = try resolveProject(try string("project", args), in: snap, create: false)
            guard let t = Backlog.next(for: project.id, in: snap.tasks) else { return "Nothing waiting." }
            return Self.line(t)

        case "task_add":
            let project = try resolveProject(try string("project", args), in: snap, create: true)
            let kind = (args["kind"] as? String).flatMap(FactoryTask.Kind.init(rawValue:)) ?? .feature
            let task = FactoryTask(projectID: project.id, title: try string("title", args), kind: kind,
                                   rank: Backlog.nextRank(for: project.id, in: snap.tasks),
                                   note: args["note"] as? String ?? "", created: now())
            try store.save(task)
            return "Filed. task_id: \(task.id.uuidString)"

        case "task_claim":
            let task = try task(args, in: snap)
            var agent = try agent(args, in: snap)
            try store.save(Backlog.set(task, to: .inProgress, agentID: agent.id, at: now()))
            agent.taskID = task.id
            agent.lastSeen = now()
            try store.save(agent)
            return "You are on: \(task.title)"

        case "task_status":
            var task = try task(args, in: snap)
            guard let state = FactoryTask.State(rawValue: try string("state", args)) else {
                throw ToolError(message: "state must be backlog, inProgress or done")
            }
            if let note = args["note"] as? String, !note.isEmpty {
                task.note = task.note.isEmpty ? note : task.note + "\n" + note
            }
            try store.save(Backlog.set(task, to: state, at: now()))
            return "\(task.title): \(state.rawValue)"

        case "task_rank":
            let task = try task(args, in: snap)
            guard let otherID = UUID(uuidString: try string("above_task_id", args)),
                  let other = snap.tasks.first(where: { $0.id == otherID }), other.projectID == task.projectID
            else { throw ToolError(message: "above_task_id is not a task on the same backlog") }
            let changed = Backlog.place(task, above: other, in: snap.tasks.filter { $0.projectID == task.projectID }, at: now())
            for t in changed { try store.save(t) }
            return "\(task.title) now sits above \(other.title)."

        case "task_remove":
            let task = try task(args, in: snap)
            try store.delete(task)
            return "Removed: \(task.title)"

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
            let escalation = Escalation(
                projectID: project.id, question: try string("question", args),
                context: args["context"] as? String ?? "", options: options,
                agentID: agent?.id, raisedBy: agent?.name ?? "agent", raised: now())
            try store.save(escalation)
            return "Raised. escalation_id: \(escalation.id.uuidString). Now call escalation_await."

        case "escalation_await":
            guard let id = UUID(uuidString: try string("escalation_id", args)) else {
                throw ToolError(message: "escalation_id is not an id")
            }
            let timeout = TimeInterval(args["timeout_seconds"] as? Int ?? 600)
            let deadline = now().addingTimeInterval(timeout)
            while true {
                guard let e = store.escalation(id) else { throw ToolError(message: "No escalation \(id.uuidString)") }
                if let chosen = e.chosen, let d = e.decision {
                    let detail = chosen.detail.isEmpty ? "" : " (\(chosen.detail))"
                    return "Decided by \(d.by): \(chosen.title)\(detail)"
                }
                if now() >= deadline { return "Still open. Call escalation_await again." }
                Thread.sleep(forTimeInterval: pollInterval)
            }

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
                return "\(e.id.uuidString)  [\(project)] \(e.question)  \(opts)"
            }.joined(separator: "\n")

        default:
            throw ToolError(message: "Unknown tool: \(name)")
        }
    }

    // MARK: Helpers

    static func line(_ t: FactoryTask) -> String {
        "\(t.id.uuidString)  \(t.state.rawValue)  \(t.kind.rawValue)  \(t.title)"
    }

    func string(_ key: String, _ args: [String: Any]) throws -> String {
        guard let v = args[key] as? String, !v.isEmpty else { throw ToolError(message: "\(key) is required") }
        return v
    }

    func agent(_ args: [String: Any], in snap: Snapshot) throws -> Agent {
        guard let id = UUID(uuidString: try string("agent_id", args)),
              let agent = snap.agents.first(where: { $0.id == id })
        else { throw ToolError(message: "Unknown agent_id. Call agent_register first.") }
        return agent
    }

    func task(_ args: [String: Any], in snap: Snapshot) throws -> FactoryTask {
        guard let id = UUID(uuidString: try string("task_id", args)),
              let task = snap.tasks.first(where: { $0.id == id })
        else { throw ToolError(message: "Unknown task_id") }
        return task
    }

    /// A folder path or a project name. A path that is not yet a project becomes one when
    /// `create` is set, so an agent can file against its own folder without a step first.
    func resolveProject(_ ref: String, in snap: Snapshot, create: Bool) throws -> Project {
        if let p = snap.projects.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) { return p }
        let path = Project.canonical(ref)
        if let p = snap.projects.first(where: { $0.id == path }) { return p }
        guard create, ref.hasPrefix("/") else {
            throw ToolError(message: "No project called \(ref). Known: \(snap.projects.map(\.name).joined(separator: ", "))")
        }
        let p = Project(path: path, added: now())
        try store.save(p)
        return p
    }
}
