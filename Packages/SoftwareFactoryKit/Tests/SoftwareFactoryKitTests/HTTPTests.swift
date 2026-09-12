import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct HTTPTests {
    func router() throws -> HTTPRouter {
        HTTPRouter(server: MCPServer(store: try temporaryStore(), pollInterval: 0.01))
    }

    func post(_ r: HTTPRouter, _ path: String, _ json: Any, origin: String? = nil) -> HTTPResponse {
        let body = try! JSONSerialization.data(withJSONObject: json)
        var headers = ["content-type": "application/json"]
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

        #expect(post(r, "/mcp", ["jsonrpc": "2.0", "method": "notifications/initialized"]).status == 202)
        #expect(r.respond(to: HTTPRequest(method: "GET", path: "/mcp")).status == 405)

        let reg = post(r, "/mcp", ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                   "params": ["name": "agent_register", "arguments": ["name": "a", "project": "/tmp/P"]]])
        #expect(reg.status == 200)
        #expect(String(decoding: reg.body, as: UTF8.self).contains("Registered"))

        let bad = r.respond(to: HTTPRequest(method: "POST", path: "/mcp", body: Data("nope".utf8)))
        #expect(bad.status == 400)
    }

    @Test func browserOriginsAreRefused() throws {
        let r = try router()
        #expect(post(r, "/mcp", ["jsonrpc": "2.0", "id": 1, "method": "ping"], origin: "https://evil.example").status == 403)
        #expect(post(r, "/mcp", ["jsonrpc": "2.0", "id": 1, "method": "ping"], origin: "http://localhost:4747").status == 200)
    }

    @Test func theAppsAPI() throws {
        let r = try router()
        let filed = post(r, "/api/task", ["project": "/tmp/P", "title": "Do it", "kind": "bug"])
        #expect(filed.status == 200)
        let task = try FileStore.decoder.decode(FactoryTask.self, from: filed.body)
        #expect(task.kind == .bug)

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

        #expect(post(r, "/api/decide", ["escalationID": UUID().uuidString, "optionID": UUID().uuidString]).status == 404)
        #expect(r.respond(to: HTTPRequest(method: "GET", path: "/nothing")).status == 404)
    }
}
