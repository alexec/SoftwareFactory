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

    public static let name = "software-factory"
    public static let version = "0.1.0"
    public static let protocolVersion = "2025-06-18"

    public init(store: FileStore, now: @escaping @Sendable () -> Date = { .now }, pollInterval: TimeInterval = 1,
                machine: @escaping @Sendable () -> MachineReading? = MCPServer.readMachine) {
        self.store = store
        self.now = now
        self.pollInterval = pollInterval
        self.machine = machine
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
        options and your recommendation, then wait for the answer (escalation_await). If a task is \
        blocked (waiting on a decision, another task, or a person), mark it (task_block) and pick up \
        the next one (task_next); the factory unblocks it when the wait is over. Before using \
        anything shared (a phone, a simulator, the browser, the whole Mac) lease it (resource_lease) and \
        release it after. Before starting anything heavy, ask the factory (factory_ask): a compile, a \
        simulator, a model. Deregister (agent_deregister) when you are finished.
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
            Tool(name: "task_add", description: "File a task on a project's backlog: at the bottom, at the top, or directly above another task.",
                 properties: ["project": str("Folder path or project name"), "title": str("The task, in one line"),
                              "kind": ["type": "string", "enum": ["feature", "bug", "chore", "review"], "description": "Defaults to feature. review is a UX review, a luxury audit or a compliance pass: findings, not a change."],
                              "position": ["type": "string", "enum": ["top", "bottom"], "description": "Defaults to bottom"],
                              "above_task_id": str("Put it directly above this task instead"),
                              "note": str("Why, and anything the next reader needs")],
                 required: ["project", "title"]),
            Tool(name: "task_claim", description: "You are on this task now. Marks it in progress under your name.",
                 properties: ["task_id": str("The task"), "agent_id": str("From agent_register")], required: ["task_id", "agent_id"]),
            Tool(name: "task_status", description: "Change a task's state: backlog, inProgress, done or parked, with a note on how it ended up.",
                 properties: ["task_id": str("The task"),
                              "state": ["type": "string", "enum": ["backlog", "inProgress", "done", "parked"]],
                              "note": str("What happened")],
                 required: ["task_id", "state"]),
            Tool(name: "task_block", description: "This task is blocked: say what it waits on, then move on to the next task. Call it once per thing it waits on; the task clears only when the last one does. A block on a decision or a task clears on its own when the decision lands or the task is done; a block on a person clears when they say so.",
                 properties: ["task_id": str("The task"),
                              "on": ["type": "string", "enum": ["decision", "task", "person", "other"], "description": "What it waits on"],
                              "id": str("The escalation_id or task_id it waits on, for decision or task"),
                              "why": str("In one line, what has to happen")],
                 required: ["task_id", "on", "why"]),
            Tool(name: "task_rank", description: "Move a task directly above another on the same backlog.",
                 properties: ["task_id": str("The task to move"), "above_task_id": str("The task it should sit above")],
                 required: ["task_id", "above_task_id"]),
            Tool(name: "task_remove", description: "Take a task off the backlog for good.",
                 properties: ["task_id": str("The task"), "reason": str("Why")], required: ["task_id"]),

            Tool(name: "escalation_raise", description: "Ask the person to decide something. Give two or more options and say which you recommend. Returns the escalation_id; then call escalation_await. Give task_id when the question stops a task: the task is marked blocked on the decision and unblocks itself when the answer lands.",
                 properties: ["agent_id": str("From agent_register"), "project": str("Folder path or project name"),
                              "task_id": str("The task this question stops, if any"),
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

            Tool(name: "resource_list", description: "Every shared resource: slots, who holds them and until when. Lease one before using a phone, a simulator, the browser or the whole Mac.",
                 properties: [:], required: []),
            Tool(name: "resource_add", description: "Define a shared resource with a number of slots and the longest lease allowed.",
                 properties: ["name": str("e.g. iPhone, Compile, Chrome"), "slots": ["type": "integer", "description": "How many can hold it at once; default 1"],
                              "max_minutes": ["type": "integer", "description": "Longest single lease, in minutes; default 60"], "note": str("What it is")],
                 required: ["name"]),
            Tool(name: "resource_lease", description: "Take one slot for up to some minutes, saying why. Returns the lease and when it runs out, or says the resource is full and when a slot frees. Leasing a resource you already hold renews it.",
                 properties: ["agent_id": str("From agent_register"), "resource": str("Resource name or id"),
                              "minutes": ["type": "integer", "description": "How long you need it; capped by the resource's longest lease"], "why": str("What for, in one line")],
                 required: ["agent_id", "resource"]),
            Tool(name: "resource_renew", description: "More time on a lease you hold.",
                 properties: ["agent_id": str("From agent_register"), "resource": str("Resource name or id"),
                              "minutes": ["type": "integer", "description": "How much longer"]],
                 required: ["agent_id", "resource"]),
            Tool(name: "resource_release", description: "Give a resource back early. Deregistering releases everything you hold.",
                 properties: ["agent_id": str("From agent_register"), "resource": str("Resource name or id")],
                 required: ["agent_id", "resource"]),

            Tool(name: "factory_status", description: "The factory right now: memory, swap, load, compiles and simulators running, the throttle, and the verdict: under, tight or over capacity.",
                 properties: [:], required: []),
            Tool(name: "factory_ask", description: "Ask before starting anything heavy: can I start a compile, a simulator, or a model? Answers yes, wait or no, with the reason. A model is the whole machine.",
                 properties: ["work": ["type": "string", "enum": ["compile", "simulator", "model"]]], required: ["work"]),
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
            let held = Leases.heldBy(agent.id, in: snap.leases, now: now())
            for var lease in held {
                lease.released = now()
                try store.save(lease)
            }
            return held.isEmpty ? "Deregistered. Thank you." : "Deregistered and released \(held.count) lease\(held.count == 1 ? "" : "s"). Thank you."

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
            let position = (args["position"] as? String).flatMap(Backlog.Position.init(rawValue:)) ?? .bottom
            var task = FactoryTask(projectID: project.id, title: try string("title", args), kind: kind,
                                   rank: Backlog.rank(for: position, projectID: project.id, in: snap.tasks),
                                   note: args["note"] as? String ?? "", created: now())
            if let aboveRef = args["above_task_id"] as? String, !aboveRef.isEmpty {
                guard let aboveID = UUID(uuidString: aboveRef),
                      let above = snap.tasks.first(where: { $0.id == aboveID }), above.projectID == project.id
                else { throw ToolError(message: "above_task_id is not a task on that backlog") }
                task.rank = above.rank
                for moved in Backlog.place(task, above: above, in: snap.tasks.filter { $0.projectID == project.id } + [task], at: now()) {
                    if moved.id == task.id { task = moved } else { try store.save(moved) }
                }
            }
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
                throw ToolError(message: "state must be backlog, inProgress, done or parked")
            }
            if let note = args["note"] as? String, !note.isEmpty {
                task.note = task.note.isEmpty ? note : task.note + "\n" + note
            }
            try store.save(Backlog.set(task, to: state, at: now()))
            return "\(task.title): \(state.rawValue)"

        case "task_block":
            let task = try task(args, in: snap)
            guard let kind = FactoryTask.Blocker.Kind(rawValue: try string("on", args)) else {
                throw ToolError(message: "on must be decision, task, person or other")
            }
            let id = (args["id"] as? String).flatMap(UUID.init(uuidString:))
            if kind == .decision || kind == .task, id == nil { throw ToolError(message: "id is needed for a block on a \(kind.rawValue)") }
            let blocked = Backlog.block(task, on: .init(kind: kind, id: id, why: try string("why", args)), at: now())
            try store.save(blocked)
            let next = Backlog.next(for: task.projectID, in: snap.tasks.filter { $0.id != task.id }).map { " Next on the backlog: \($0.title) (\($0.id.uuidString))." } ?? " Nothing else is waiting on this backlog."
            let count = blocked.blockers.count
            return "\(task.title) is blocked on \(count) thing\(count == 1 ? "" : "s").\(next)"

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
            var task: FactoryTask?
            if let ref = args["task_id"] as? String, !ref.isEmpty { task = try self.task(args, in: snap) }
            let escalation = Escalation(
                projectID: project.id, question: try string("question", args),
                context: args["context"] as? String ?? "", options: options,
                agentID: agent?.id, taskID: task?.id, raisedBy: agent?.name ?? "agent", raised: now())
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
                let stops = e.taskID.flatMap { id in snap.tasks.first { $0.id == id } }.map { "  stops: \($0.title)" } ?? ""
                return "\(e.id.uuidString)  [\(project)] \(e.question)  \(opts)\(stops)"
            }.joined(separator: "\n")

        case "resource_list":
            if snap.resources.isEmpty { return "No resources defined. resource_add makes one." }
            return snap.resources.sorted { $0.name < $1.name }.map { r in
                let held = Leases.held(for: r.id, in: snap.leases, agents: snap.agents, now: now())
                let free = r.slots - held.count
                let holders = held.map { l in
                    let who = snap.agents.first { $0.id == l.agentID }?.name ?? "someone"
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
                    let name = snap.agents.first { $0.id == l.agentID }?.name ?? "someone"
                    return l.until <= now() ? "\(name), overdue since \(Self.clock(l.until)) and still on the floor" : name
                }.joined(separator: ", ")
                let frees = nextFree > now() ? "A slot frees at \(Self.clock(nextFree))." : "No slot has a known end: the holder's job outlived its lease."
                return "\(resource.name) is full (held by \(who)). \(frees) Do something else and ask again."
            }

        case "resource_renew":
            let agent = try agent(args, in: snap)
            let resource = try resource(args, in: snap)
            guard let mine = Leases.held(for: resource.id, in: snap.leases, agents: snap.agents, now: now()).first(where: { $0.agentID == agent.id }) else {
                throw ToolError(message: "You do not hold \(resource.name).")
            }
            let minutes = TimeInterval(args["minutes"] as? Int ?? Int(resource.maxLease / 60))
            let renewed = try Leases.renew(mine, of: resource, for: agent.id, wanting: minutes * 60, now: now())
            try store.save(renewed)
            return "\(resource.name) is yours until \(Self.clock(renewed.until))."

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

    static func line(_ t: FactoryTask) -> String {
        let blocked = t.blockers.isEmpty ? "" : "  [blocked on " + t.blockers.map { "\($0.kind.rawValue): \($0.why)" }.joined(separator: "; ") + "]"
        return "\(t.id.uuidString)  \(t.state.rawValue)  \(t.kind.rawValue)  \(t.title)\(blocked)"
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
