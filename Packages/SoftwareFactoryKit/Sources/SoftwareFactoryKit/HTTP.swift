import Foundation

/// The smallest HTTP the factory needs: one request in, one response out, as values.
/// Sockets live in the app; this is the part a test can hold.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// Parses one request from the front of `data`. Returns nil until the whole request,
    /// headers and body, has arrived; `consumed` says how many bytes it took.
    public static func parse(_ data: Data) -> (request: HTTPRequest, consumed: Int)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return nil }
        let body = data[bodyStart..<(bodyStart + length)]
        let request = HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: Data(body))
        return (request, bodyStart + length - data.startIndex)
    }

    /// The bytes a client sends. Host is whatever the caller connected to.
    public func serialized(host: String) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        return HTTPResponse(status: status, headers: headers.merging(["Content-Type": "application/json"]) { _, contentType in contentType }, body: data)
    }

    public static func encoded<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? FileStore.encoder.encode(value)) ?? Data()
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    public static func text(_ text: String, status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }

    /// Parses one response from the front of `data`, the mirror of `HTTPRequest.parse`.
    public static func parse(_ data: Data) -> (response: HTTPResponse, consumed: Int)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return nil }
        let body = Data(data[bodyStart..<(bodyStart + length)])
        return (HTTPResponse(status: status, headers: headers, body: body), bodyStart + length - data.startIndex)
    }

    public var serialized: Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Status"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "keep-alive"
        for (k, v) in all.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Routes the factory's two surfaces:
///
/// - `POST /mcp`: the MCP streamable-HTTP endpoint. JSON-RPC in, JSON-RPC out; a
///   notification gets 202 with no body. `GET /mcp` is 405: the server never pushes.
/// - `/api/*`: what the apps use. `GET /api/snapshot` is the whole store as JSON, which the
///   phone turns into its own dashboard with `Dashboard.make`;
///   `POST /api/decide` records a decision; `POST /api/task` files a task;
///   `POST /api/task/set` parks or unparks; `POST /api/task/place` ranks one above
///   another; `POST /api/task/move` is the list's onMove.
public struct HTTPRouter: Sendable {
    public let server: MCPServer
    private let sessions = MCPSessions()

    public init(server: MCPServer) {
        self.server = server
    }

    public var store: FileStore { server.store }

    public func respond(to request: HTTPRequest) -> HTTPResponse {
        // Only the machine itself and its own network may talk to the factory; a browser
        // page must not. A browser always sends Origin, so an Origin that is not ours is refused.
        if let origin = request.headers["origin"], !Self.originAllowed(origin) {
            return .text("Forbidden origin", status: 403)
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        // An agent reached at its own address, `/mcp/<its id>`. The factory hands each ACP
        // agent one at `session/new`, so the caller is the address and does not have to
        // say who it is on every call. (T373.)
        if request.method == "POST", path.hasPrefix("/mcp/") {
            let caller = String(path.dropFirst("/mcp/".count))
            guard !caller.isEmpty, !caller.contains("/") else { return .text("Not found", status: 404) }
            return mcp(request, as: caller)
        }
        switch (request.method, path) {
        case ("POST", "/mcp"):
            return mcp(request)
        case ("GET", "/mcp"):
            return .text("This server does not open a stream; POST JSON-RPC here.", status: 405)
        case ("DELETE", "/mcp"):
            guard let sessionID = sessionID(in: request), let agent = sessions.remove(sessionID) else {
                return .text("Unknown MCP session", status: 404)
            }
            if let agent {
                do {
                    try server.setConnection(connected: false, for: agent)
                } catch {
                    return .text("\(error)", status: 500)
                }
            }
            return HTTPResponse(status: 200)
        // An agent's conversation, for the phone. The transcript is a file under the
        // store, so this reads it the same way it reads any other record and needs
        // nothing from the daemon. `after` is how many lines the phone already has, so a
        // poll carries the new ones rather than the whole thing every three seconds.
        // (Alex, 16 Sep 2026: bring chatting to the iPhone.)
        case ("GET", "/api/transcript"):
            return transcript(request)
        // Words for an agent, from the phone. Written down as a message, which the app
        // delivers the way it delivers a nudge: one path, so the mailbox, the queueing
        // and the transcript all behave as they already do.
        case ("POST", "/api/say"):
            return say(request.body)
        case ("GET", "/api/snapshot"):
            do { return .encoded(try store.load()) } catch { return .text("\(error)", status: 500) }
        case ("POST", "/api/decide"):
            return decide(request.body)
        case ("POST", "/api/task"):
            return task(request.body)
        case ("POST", "/api/task/edit"):
            return editTask(request.body)
        case ("POST", "/api/task/set"):
            return setTask(request.body)
        case ("POST", "/api/task/place"):
            return placeTask(request.body)
        case ("POST", "/api/task/move"):
            return moveTask(request.body)
        case ("GET", "/"):
            return .text("Taktu: Software Factory. MCP at /mcp; the apps use /api.", status: 200)
        default:
            return .text("Not found", status: 404)
        }
    }

    static func originAllowed(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// One agent's conversation, folded, and how many raw lines it was folded from so the
    /// caller can ask for the rest next time.
    public struct Conversation: Codable, Sendable {
        public var lines: [String]
        public var total: Int

        public init(lines: [String], total: Int) {
            self.lines = lines
            self.total = total
        }
    }

    func transcript(_ request: HTTPRequest) -> HTTPResponse {
        let query = request.path.split(separator: "?").dropFirst().joined(separator: "?")
        var wanted: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            wanted[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        guard let raw = wanted["agent"], let agent = UUID(uuidString: raw) else {
            return .text("agent is required", status: 400)
        }
        let all = store.transcriptLines(for: agent)
        let after = wanted["after"].flatMap(Int.init) ?? 0
        let from = min(max(after, 0), all.count)
        return .encoded(Conversation(lines: Array(all[from...]), total: all.count))
    }

    public struct Said: Codable, Sendable {
        public var agent: UUID
        public var text: String

        public init(agent: UUID, text: String) {
            self.agent = agent
            self.text = text
        }
    }

    func say(_ body: Data) -> HTTPResponse {
        guard let said = try? JSONDecoder().decode(Said.self, from: body) else {
            return .text("Expected agent and text", status: 400)
        }
        let words = said.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return .text("Nothing to say", status: 400) }
        do {
            let snap = try store.load()
            guard let agent = snap.agents.first(where: { $0.id == said.agent }), agent.isRegistered else {
                return .text("Unknown agent", status: 404)
            }
            try store.save(AgentMessage(recipientID: agent.id, from: "Alex",
                                        subject: "You", contents: words))
            return HTTPResponse(status: 200)
        } catch {
            return .text("\(error)", status: 500)
        }
    }

    func mcp(_ request: HTTPRequest, as caller: String? = nil) -> HTTPResponse {
        guard let parsed = try? JSONSerialization.jsonObject(with: request.body) else {
            return .json(MCPServer.error(id: nil, code: -32700, message: "Parse error"), status: 400)
        }
        if let batch = parsed as? [[String: Any]] {
            // An agent at its own address needs no transport session: the address is who
            // it is, and a session is something any caller can ask for. (T373.)
            if caller != nil {
                let responses = batch.compactMap { handle($0, sessionID: UUID(), as: caller) }
                return responses.isEmpty ? HTTPResponse(status: 202) : .json(responses)
            }
            guard let sessionID = sessionID(in: request) else {
                return .text("Mcp-Session-Id is required", status: 400)
            }
            guard sessions.contains(sessionID) else {
                return .text("Unknown MCP session", status: 404)
            }
            let responses = batch.compactMap { handle($0, sessionID: sessionID, as: caller) }
            return responses.isEmpty ? HTTPResponse(status: 202) : .json(responses)
        }
        guard let one = parsed as? [String: Any] else {
            return .json(MCPServer.error(id: nil, code: -32600, message: "Invalid request"), status: 400)
        }
        let method = one["method"] as? String
        if method == "initialize" {
            guard request.headers["mcp-session-id"] == nil else {
                return .text("MCP session is assigned during initialization", status: 400)
            }
            let sessionID = sessions.create()
            guard let response = server.handle(one, as: caller) else { return HTTPResponse(status: 202) }
            return .json(response, headers: ["Mcp-Session-Id": sessionID.uuidString])
        }
        if caller != nil {
            guard let response = handle(one, sessionID: UUID(), as: caller)
            else { return HTTPResponse(status: 202) }
            return .json(response)
        }
        guard let sessionID = sessionID(in: request) else {
            return .text("Mcp-Session-Id is required", status: 400)
        }
        guard sessions.contains(sessionID) else {
            return .text("Unknown MCP session", status: 404)
        }
        guard let response = handle(one, sessionID: sessionID, as: caller) else { return HTTPResponse(status: 202) }
        return .json(response)
    }

    /// The transport's session is not the agent's. The agent says who it is in the call
    /// itself, so nothing here has to remember one across requests.
    /// (T-session, 13 Sep 2026.)
    func handle(_ request: [String: Any], sessionID: UUID, as caller: String? = nil) -> [String: Any]? {
        server.handle(request, agentID: nil, as: caller)
    }

    func sessionID(in request: HTTPRequest) -> UUID? {
        request.headers["mcp-session-id"].flatMap(UUID.init(uuidString:))
    }

    private final class MCPSessions: @unchecked Sendable {
        private let lock = NSLock()
        private var ids = Set<UUID>()
        private var agents: [UUID: String] = [:]

        func create() -> UUID {
            lock.lock()
            defer { lock.unlock() }
            let id = UUID()
            ids.insert(id)
            return id
        }

        func contains(_ id: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return ids.contains(id)
        }

        func remove(_ id: UUID) -> String?? {
            lock.lock()
            defer { lock.unlock() }
            guard ids.remove(id) != nil else { return nil }
            return agents.removeValue(forKey: id)
        }

        func agent(for sessionID: UUID) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return agents[sessionID]
        }

        func setAgent(_ agentID: String, for sessionID: UUID) {
            lock.lock()
            defer { lock.unlock() }
            agents[sessionID] = agentID
        }
    }

    /// An option with an optional note, or `answer` alone for the person's own words.
    struct DecideBody: Decodable {
        var escalationID: UUID
        var optionID: UUID?
        var note: String?
        var answer: String?
        var by: String?
    }

    func decide(_ body: Data) -> HTTPResponse {
        guard let d = try? FileStore.decoder.decode(DecideBody.self, from: body) else {
            return .text("Body: {escalationID, optionID?, note?, answer?, by?}", status: 400)
        }
        guard var e = store.escalation(d.escalationID) else { return .text("No such escalation", status: 404) }
        do {
            if let optionID = d.optionID {
                guard let option = e.options.first(where: { $0.id == optionID }) else { return .text("No such option", status: 404) }
                try e.decide(option, note: d.note ?? "", by: d.by ?? "phone", at: server.now())
            } else if let answer = d.answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try e.answer(answer, by: d.by ?? "phone", at: server.now())
            } else {
                return .text("Body: {escalationID, optionID?, note?, answer?, by?}", status: 400)
            }
            try store.save(e)
        } catch { return .text("\(error)", status: 500) }
        return .encoded(e)
    }

    struct TaskBody: Decodable {
        var project: String
        var title: String
        var position: Backlog.Position?
        var note: String?
        var work: String?
    }

    func task(_ body: Data) -> HTTPResponse {
        guard let t = try? FileStore.decoder.decode(TaskBody.self, from: body) else {
            return .text("Body: {project (name or id), title, position?, note?, work?}", status: 400)
        }
        do {
            let snap = try store.load()
            let project = try server.resolveProject(t.project, in: snap, create: true)
            let position = t.position ?? .bottom
            let work: FactoryTask.Work
            if t.work == nil {
                work = FactoryTask.Work.reading(title: t.title).work
            } else if let parsed = parsedWork(t.work, defaulting: false) {
                work = parsed
            } else {
                return .text("work must be design, plan, code, implement, fix, review, investigate or ship.", status: 400)
            }
            let task = FactoryTask(number: Backlog.nextNumber(in: (try? store.loadEveryTask()) ?? snap.tasks),
                                   projectID: project.id, title: t.title,
                                   state: Backlog.state(for: position),
                                   rank: Backlog.rank(for: position, projectID: project.id, in: snap.tasks),
                                   note: t.note ?? "", work: work, created: server.now())
            try store.save(task)
            return .encoded(task)
        } catch let e as MCPServer.ToolError {
            return .text(e.message, status: 400)
        } catch { return .text("\(error)", status: 500) }
    }

    struct EditTaskBody: Decodable {
        var id: UUID
        var title: String
        var note: String
        var work: String?
    }

    func editTask(_ body: Data) -> HTTPResponse {
        guard let edited = try? FileStore.decoder.decode(EditTaskBody.self, from: body) else {
            return .text("Body: {id, title, note, work?}", status: 400)
        }
        do {
            guard let task = try store.load().tasks.first(where: { $0.id == edited.id }) else {
                return .text("No such task", status: 404)
            }
            let work: FactoryTask.Work?
            if edited.work != nil {
                guard let parsed = parsedWork(edited.work, defaulting: false) else {
                    return .text("work must be design, plan, code, implement, fix, review, investigate or ship.", status: 400)
                }
                work = parsed
            } else {
                work = FactoryTask.Work.reading(title: edited.title).work
            }
            let updated = Backlog.edit(task, title: edited.title, note: edited.note, work: work, at: server.now())
            guard updated.title == edited.title.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return .text("A task needs a title", status: 400)
            }
            try store.save(updated)
            return .encoded(updated)
        } catch {
            return .text("\(error)", status: 500)
        }
    }

    func parsedWork(_ raw: String?, defaulting: Bool) -> FactoryTask.Work? {
        guard let raw, !raw.isEmpty else { return defaulting ? .implement : nil }
        return FactoryTask.Work.parse(raw)
    }

    struct SetTaskBody: Decodable {
        var id: UUID
        var state: String
    }

    func setTask(_ body: Data) -> HTTPResponse {
        guard let asked = try? FileStore.decoder.decode(SetTaskBody.self, from: body),
              let state = FactoryTask.State(rawValue: asked.state)
        else {
            return .text("Body: {id, state (backlog or parked)}", status: 400)
        }
        guard Backlog.personMaySet.contains(state) else {
            return .text("The person parks and unparks. In progress and done are an agent's to say.", status: 400)
        }
        do {
            guard let task = try store.load().tasks.first(where: { $0.id == asked.id }) else {
                return .text("No such task", status: 404)
            }
            let updated = Backlog.set(task, to: state, at: server.now())
            try store.save(updated)
            return .encoded(updated)
        } catch {
            return .text("\(error)", status: 500)
        }
    }

    struct PlaceTaskBody: Decodable {
        var id: UUID
        var above: UUID
    }

    func placeTask(_ body: Data) -> HTTPResponse {
        guard let asked = try? FileStore.decoder.decode(PlaceTaskBody.self, from: body) else {
            return .text("Body: {id, above}", status: 400)
        }
        do {
            let snap = try store.load()
            guard var task = snap.tasks.first(where: { $0.id == asked.id }) else {
                return .text("No such task", status: 404)
            }
            guard let other = snap.tasks.first(where: { $0.id == asked.above }) else {
                return .text("No such task to place above", status: 404)
            }
            guard task.id != other.id, Backlog.personMaySet.contains(other.state) else {
                return .text("Place above a backlog or parked row.", status: 400)
            }
            if task.state != other.state {
                task.state = other.state
                task.agentID = nil
            }
            let siblings = snap.tasks.filter { $0.projectID == task.projectID && $0.state == other.state && $0.id != task.id }
            let changed = Backlog.place(task, above: other, in: siblings + [task], states: [other.state], at: server.now())
            for t in changed { try store.save(t) }
            if !changed.contains(where: { $0.id == task.id }) { try store.save(task) }
            let placed = (try store.load().tasks.first { $0.id == task.id }) ?? task
            return .encoded(placed)
        } catch {
            return .text("\(error)", status: 500)
        }
    }

    struct MoveTaskBody: Decodable {
        var ids: [UUID]
        var to: Int
        var state: String
    }

    func moveTask(_ body: Data) -> HTTPResponse {
        guard let asked = try? FileStore.decoder.decode(MoveTaskBody.self, from: body),
              let state = FactoryTask.State(rawValue: asked.state)
        else {
            return .text("Body: {ids, to, state (backlog or parked)}", status: 400)
        }
        guard Backlog.personMaySet.contains(state) else {
            return .text("The person ranks the backlog and what is parked.", status: 400)
        }
        do {
            let snap = try store.load()
            guard let first = asked.ids.first, let sample = snap.tasks.first(where: { $0.id == first }) else {
                return .text("No such task", status: 404)
            }
            let open = snap.tasks.filter { $0.projectID == sample.projectID && $0.state == state }.sorted(by: Backlog.order)
            var source = IndexSet()
            for id in asked.ids {
                guard let i = open.firstIndex(where: { $0.id == id }) else {
                    return .text("No such task", status: 404)
                }
                source.insert(i)
            }
            let changed = Backlog.move(in: open, from: source, to: asked.to, states: [state], at: server.now())
            for t in changed { try store.save(t) }
            return .encoded(changed)
        } catch {
            return .text("\(error)", status: 500)
        }
    }

}
