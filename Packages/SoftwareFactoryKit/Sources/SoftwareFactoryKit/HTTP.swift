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
///   `POST /api/decide` records a decision; `POST /api/task` files a task.
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
        switch (request.method, request.path.split(separator: "?").first.map(String.init) ?? request.path) {
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
        case ("GET", "/api/snapshot"):
            do { return .encoded(try store.load()) } catch { return .text("\(error)", status: 500) }
        case ("POST", "/api/decide"):
            return decide(request.body)
        case ("POST", "/api/task"):
            return task(request.body)
        case ("POST", "/api/task/edit"):
            return editTask(request.body)
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

    func mcp(_ request: HTTPRequest) -> HTTPResponse {
        guard let parsed = try? JSONSerialization.jsonObject(with: request.body) else {
            return .json(MCPServer.error(id: nil, code: -32700, message: "Parse error"), status: 400)
        }
        if let batch = parsed as? [[String: Any]] {
            guard let sessionID = sessionID(in: request) else {
                return .text("Mcp-Session-Id is required", status: 400)
            }
            guard sessions.contains(sessionID) else {
                return .text("Unknown MCP session", status: 404)
            }
            let responses = batch.compactMap { handle($0, sessionID: sessionID) }
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
            guard let response = server.handle(one) else { return HTTPResponse(status: 202) }
            return .json(response, headers: ["Mcp-Session-Id": sessionID.uuidString])
        }
        guard let sessionID = sessionID(in: request) else {
            return .text("Mcp-Session-Id is required", status: 400)
        }
        guard sessions.contains(sessionID) else {
            return .text("Unknown MCP session", status: 404)
        }
        guard let response = handle(one, sessionID: sessionID) else { return HTTPResponse(status: 202) }
        return .json(response)
    }

    func handle(_ request: [String: Any], sessionID: UUID) -> [String: Any]? {
        let response = server.handle(request, agentID: sessions.agent(for: sessionID))
        guard MCPServer.isAgentRegistration(request),
              let response,
              let label = MCPServer.registeredAgentLabel(in: response)
        else { return response }
        sessions.setAgent(label, for: sessionID)
        return response
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
    }

    func task(_ body: Data) -> HTTPResponse {
        guard let t = try? FileStore.decoder.decode(TaskBody.self, from: body) else {
            return .text("Body: {project (name or id), title, position?, note?}", status: 400)
        }
        do {
            let snap = try store.load()
            let project = try server.resolveProject(t.project, in: snap, create: true)
            let position = t.position ?? .bottom
            let task = FactoryTask(number: Backlog.nextNumber(in: (try? store.loadEveryTask()) ?? snap.tasks),
                                   projectID: project.id, title: t.title,
                                   state: Backlog.state(for: position),
                                   rank: Backlog.rank(for: position, projectID: project.id, in: snap.tasks),
                                   note: t.note ?? "", created: server.now())
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
    }

    func editTask(_ body: Data) -> HTTPResponse {
        guard let edited = try? FileStore.decoder.decode(EditTaskBody.self, from: body) else {
            return .text("Body: {id, title, note}", status: 400)
        }
        do {
            guard let task = try store.load().tasks.first(where: { $0.id == edited.id }) else {
                return .text("No such task", status: 404)
            }
            let updated = Backlog.edit(task, title: edited.title, note: edited.note, at: server.now())
            guard updated.title == edited.title.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return .text("A task needs a title", status: 400)
            }
            try store.save(updated)
            return .encoded(updated)
        } catch {
            return .text("\(error)", status: 500)
        }
    }

}
