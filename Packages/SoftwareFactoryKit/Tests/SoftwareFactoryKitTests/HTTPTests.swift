import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct HTTPTests {
    func router() throws -> HTTPRouter {
        HTTPRouter(server: MCPServer(store: try temporaryStore(), pollInterval: 0.01))
    }

    func post(_ r: HTTPRouter, _ path: String, _ json: Any, origin: String? = nil, headers extraHeaders: [String: String] = [:]) -> HTTPResponse {
        let body = try! JSONSerialization.data(withJSONObject: json)
        var headers = ["content-type": "application/json"].merging(extraHeaders) { _, extra in extra }
        if let origin { headers["origin"] = origin }
        return r.respond(to: HTTPRequest(method: "POST", path: path, headers: headers, body: body))
    }

    @Test func parsesARequestOnlyWhenWhole() throws {
        let raw = Data("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhel".utf8)
        #expect(HTTPRequest.parse(raw) == nil)
        let whole = raw + Data("lo{next".utf8)
        let (req, consumed) = try #require(HTTPRequest.parse(whole))
        #expect(req.method == "POST")
        #expect(req.path == "/mcp")
        #expect(req.headers["host"] == "x")
        #expect(String(decoding: req.body, as: UTF8.self) == "hello")
        #expect(consumed == raw.count + 2)
    }

    @Test func aRequestAndAResponseRoundTripThroughBytes() throws {
        let request = HTTPRequest(method: "POST", path: "/api/decide", headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        let (back, _) = try #require(HTTPRequest.parse(request.serialized(host: "factory")))
        #expect(back.method == "POST")
        #expect(back.path == "/api/decide")
        #expect(back.headers["host"] == "factory")
        #expect(back.body == request.body)

        let response = HTTPResponse.text("hello", status: 404)
        let (parsed, consumed) = try #require(HTTPResponse.parse(response.serialized + Data("extra".utf8)))
        #expect(parsed.status == 404)
        #expect(String(decoding: parsed.body, as: UTF8.self) == "hello")
        #expect(consumed == response.serialized.count)
        #expect(HTTPResponse.parse(response.serialized.dropLast(2)) == nil)
    }

    @Test func serializesAResponse() {
        let text = String(decoding: HTTPResponse.text("hi", status: 200).serialized, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.hasSuffix("\r\n\r\nhi"))
    }

    @Test func mcpOverHTTP() throws {
        let r = try router()
        let init_ = post(r, "/mcp", ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        #expect(init_.status == 200)
        let obj = try JSONSerialization.jsonObject(with: init_.body) as! [String: Any]
        #expect(((obj["result"] as! [String: Any])["serverInfo"] as! [String: Any])["name"] as? String == "software-factory")
        let sessionID = try #require(init_.headers["Mcp-Session-Id"].flatMap(UUID.init(uuidString:)))

        #expect(post(r, "/mcp", ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]).status == 400)
        #expect(post(r, "/mcp", ["jsonrpc": "2.0", "method": "notifications/initialized"],
                     headers: ["mcp-session-id": sessionID.uuidString]).status == 202)
        #expect(r.respond(to: HTTPRequest(method: "GET", path: "/mcp")).status == 405)

        // No registering: the factory writes the agent down, so the test does too.
        let agent = Agents.reserve(number: try r.store.takeAgentNumber(), projectID: nil)
        try r.store.save(agent)
        #expect(try r.store.load().agents.first?.label == "A1")

        // A tool call carries the agent's own session, which is not the transport's
        // MCP session, and the reply never leaks the transport's.
        let listed = post(r, "/mcp", ["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                      "params": ["name": "agent_list", "arguments": ["session_id": agent.id.uuidString]]],
                          headers: ["mcp-session-id": sessionID.uuidString])
        #expect(String(decoding: listed.body, as: UTF8.self).contains("No other agents are registered."))
        #expect(!String(decoding: listed.body, as: UTF8.self).contains(sessionID.uuidString))

        let bad = r.respond(to: HTTPRequest(method: "POST", path: "/mcp", body: Data("nope".utf8)))
        #expect(bad.status == 400)
    }

    @Test func browserOriginsAreRefused() throws {
        let r = try router()
        #expect(post(r, "/mcp", ["jsonrpc": "2.0", "id": 1, "method": "ping"], origin: "https://evil.example").status == 403)
        let init_ = post(r, "/mcp", ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": [:]], origin: "http://localhost:4747")
        let sessionID = try #require(init_.headers["Mcp-Session-Id"])
        #expect(post(r, "/mcp", ["jsonrpc": "2.0", "id": 3, "method": "ping"],
                     origin: "http://localhost:4747", headers: ["mcp-session-id": sessionID]).status == 200)
    }

    @Test func theAppsAPIFilesWork() throws {
        let r = try router()
        let designed = post(r, "/api/task", ["project": "/tmp/P", "title": "The add row", "work": "design"])
        #expect(designed.status == 200)
        let task = try FileStore.decoder.decode(FactoryTask.self, from: designed.body)
        #expect(task.work == .design)
        let planned = post(r, "/api/task/edit", ["id": task.id.uuidString, "title": "The add row", "note": "", "work": "plan"])
        #expect(try FileStore.decoder.decode(FactoryTask.self, from: planned.body).work == .plan)
        #expect(post(r, "/api/task", ["project": "/tmp/P", "title": "No", "work": "feature"]).status == 400)
        let plain = post(r, "/api/task", ["project": "/tmp/P", "title": "Do it"])
        #expect(try FileStore.decoder.decode(FactoryTask.self, from: plain.body).work == .implement)
        let coded = post(r, "/api/task", ["project": "/tmp/P", "title": "Do it", "work": "code"])
        #expect(try FileStore.decoder.decode(FactoryTask.self, from: coded.body).work == .implement)
        let fromTitle = post(r, "/api/task", ["project": "/tmp/P", "title": "Design a sheet"])
        #expect(try FileStore.decoder.decode(FactoryTask.self, from: fromTitle.body).work == .design)
    }

    @Test func theAppsAPI() throws {
        let r = try router()
        let filed = post(r, "/api/task", ["project": "/tmp/P", "title": "Do it"])
        #expect(filed.status == 200)
        let task = try FileStore.decoder.decode(FactoryTask.self, from: filed.body)
        let edited = post(r, "/api/task/edit", ["id": task.id.uuidString, "title": "Do it well", "note": "first"])
        #expect(edited.status == 200)
        #expect(try FileStore.decoder.decode(FactoryTask.self, from: edited.body).title == "Do it well")
        #expect(post(r, "/api/task/edit", ["id": task.id.uuidString, "title": " ", "note": ""]).status == 400)
        #expect(task.work == .implement)

        var e = Escalation(projectID: "/tmp/P", question: "q", options: [.init(title: "A", recommended: true), .init(title: "B")])
        try r.store.save(e)
        let decided = post(r, "/api/decide", ["escalationID": e.id.uuidString, "optionID": e.options[1].id.uuidString, "by": "phone"])
        #expect(decided.status == 200)
        e = try FileStore.decoder.decode(Escalation.self, from: decided.body)
        #expect(e.chosen?.title == "B")
        #expect(e.decision?.by == "phone")

        let snap = r.respond(to: HTTPRequest(method: "GET", path: "/api/snapshot"))
        #expect(snap.status == 200)
        let decoded = try FileStore.decoder.decode(Snapshot.self, from: snap.body)
        #expect(decoded.tasks.count == 1)
        #expect(decoded.escalations.first?.isOpen == false)

        let noted = post(r, "/api/decide", ["escalationID": e.id.uuidString, "optionID": e.options[0].id.uuidString, "note": "after lunch"])
        #expect(try FileStore.decoder.decode(Escalation.self, from: noted.body).answer == "A. after lunch")
        let own = post(r, "/api/decide", ["escalationID": e.id.uuidString, "answer": "neither, drop it", "by": "alex, phone"])
        #expect(own.status == 200)
        #expect(try FileStore.decoder.decode(Escalation.self, from: own.body).answeredInOwnWords)
        #expect(post(r, "/api/decide", ["escalationID": e.id.uuidString, "answer": " "]).status == 400)
        #expect(post(r, "/api/note", ["project": "P", "text": "steer left"]).status == 404)
        #expect(post(r, "/api/decide", ["escalationID": UUID().uuidString, "optionID": UUID().uuidString]).status == 404)
        #expect(post(r, "/api/nudge", ["agentID": UUID().uuidString]).status == 404)
        #expect(r.respond(to: HTTPRequest(method: "GET", path: "/nothing")).status == 404)
    }

    @Test func theAppsAPIParksPlacesAndMoves() throws {
        let r = try router()
        let first = try FileStore.decoder.decode(FactoryTask.self, from: post(r, "/api/task", ["project": "/tmp/P", "title": "First"]).body)
        let second = try FileStore.decoder.decode(FactoryTask.self, from: post(r, "/api/task", ["project": "/tmp/P", "title": "Second"]).body)
        let parked = post(r, "/api/task/set", ["id": first.id.uuidString, "state": "parked"])
        #expect(try FileStore.decoder.decode(FactoryTask.self, from: parked.body).state == .parked)
        #expect(post(r, "/api/task/set", ["id": second.id.uuidString, "state": "done"]).status == 400)
        let back = post(r, "/api/task/place", ["id": first.id.uuidString, "above": second.id.uuidString])
        let placed = try FileStore.decoder.decode(FactoryTask.self, from: back.body)
        #expect(placed.state == .backlog)
        #expect(placed.rank <= second.rank)
        let third = try FileStore.decoder.decode(FactoryTask.self, from: post(r, "/api/task", ["project": "/tmp/P", "title": "Third"]).body)
        let moved = post(r, "/api/task/move", ["ids": [third.id.uuidString], "to": 0, "state": "backlog"])
        #expect(moved.status == 200)
        let ordered = try r.store.load().tasks.filter { $0.state == .backlog }.sorted(by: Backlog.order)
        #expect(ordered.first?.title == "Third")
    }
}
