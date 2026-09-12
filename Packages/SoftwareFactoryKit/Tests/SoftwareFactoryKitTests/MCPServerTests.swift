import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct MCPServerTests {
    func server() throws -> MCPServer {
        MCPServer(store: try temporaryStore(), pollInterval: 0.01)
    }

    func call(_ s: MCPServer, _ tool: String, _ args: [String: Any] = [:], id: Int = 1) -> (text: String, isError: Bool) {
        let response = s.handle(["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                 "params": ["name": tool, "arguments": args]])!
        let result = response["result"] as! [String: Any]
        let content = result["content"] as! [[String: Any]]
        return (content[0]["text"] as! String, result["isError"] as! Bool)
    }

    func id(after prefix: String, in text: String) -> String {
        text.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }.first { $0.count == 36 } ?? ""
    }

    @Test func handshakeAndToolList() throws {
        let s = try server()
        let init_ = s.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                              "params": ["protocolVersion": "2025-03-26", "capabilities": [:]]])!
        let result = init_["result"] as! [String: Any]
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "software-factory")

        #expect(s.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)

        let list = s.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])!
        let tools = (list["result"] as! [String: Any])["tools"] as! [[String: Any]]
        let names = tools.map { $0["name"] as! String }
        #expect(names.contains("escalation_raise"))
        #expect(names.contains("escalation_await"))
        #expect(names.contains("agent_register"))
        #expect(names.allSatisfy { $0.allSatisfy { $0.isLetter || $0 == "_" } })

        let unknown = s.handle(["jsonrpc": "2.0", "id": 3, "method": "nope"])!
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func theNarrowSlice() throws {
        let s = try server()
        let reg = call(s, "agent_register", ["name": "packed-lead", "project": "/tmp/Packed"])
        #expect(!reg.isError)
        let agentID = id(after: "agent_id:", in: reg.text)
        #expect(UUID(uuidString: agentID) != nil)

        let raised = call(s, "escalation_raise", [
            "agent_id": agentID, "project": "Packed", "question": "Which weather source?",
            "context": "Two choices.",
            "options": [["title": "WeatherKit", "detail": "Apple's"], ["title": "Open-Meteo"]],
            "recommended": 0,
        ])
        #expect(!raised.isError)
        let escID = id(after: "escalation_id:", in: raised.text)

        let snap = try s.store.load()
        #expect(snap.projects.map(\.name) == ["Packed"])
        let e = try #require(snap.escalations.first)
        #expect(e.raisedBy == "packed-lead")
        #expect(e.recommended?.title == "WeatherKit")
        #expect(e.isOpen)

        // Nobody has decided: await times out and says so.
        let clock = Clock()
        let ticking = MCPServer(store: s.store, now: { clock.tick() }, pollInterval: 0)
        let open = call(ticking, "escalation_await", ["escalation_id": escID, "timeout_seconds": 3])
        #expect(open.text.hasPrefix("Still open"))

        // The person decides in the app; the same store, another process.
        var decided = e
        try decided.decide(decided.options[1], by: "alex")
        try s.store.save(decided)
        let answer = call(s, "escalation_await", ["escalation_id": escID, "timeout_seconds": 1])
        #expect(answer.text == "Decided by alex: Open-Meteo")

        let bye = call(s, "agent_deregister", ["agent_id": agentID])
        #expect(!bye.isError)
        #expect(try s.store.load().agents[0].deregistered != nil)
    }

    @Test func tasksRoundTrip() throws {
        let s = try server()
        let agentID = id(after: "", in: call(s, "agent_register", ["name": "a", "project": "/tmp/Where"]).text)
        let t1 = id(after: "", in: call(s, "task_add", ["project": "Where", "title": "First", "kind": "bug"]).text)
        let t2 = id(after: "", in: call(s, "task_add", ["project": "Where", "title": "Second"]).text)
        #expect(call(s, "task_next", ["project": "Where"]).text.contains("First"))
        let t0 = id(after: "", in: call(s, "task_add", ["project": "Where", "title": "Urgent", "position": "top"]).text)
        #expect(call(s, "task_next", ["project": "Where"]).text.contains("Urgent"))
        #expect(call(s, "task_remove", ["task_id": t0]).text == "Removed: Urgent")

        #expect(call(s, "task_rank", ["task_id": t2, "above_task_id": t1]).text.contains("Second now sits above First"))
        #expect(call(s, "task_next", ["project": "Where"]).text.contains("Second"))

        #expect(call(s, "task_claim", ["task_id": t1, "agent_id": agentID]).text == "You are on: First")
        let list = call(s, "task_list", ["project": "Where"]).text
        #expect(list.split(separator: "\n").first?.contains("inProgress  bug  First") == true)

        #expect(call(s, "task_status", ["task_id": t1, "state": "done", "note": "fixed by splitting on pauses"]).text == "First: done")
        let snap = try s.store.load()
        #expect(snap.tasks.first { $0.title == "First" }?.note == "fixed by splitting on pauses")

        #expect(call(s, "task_remove", ["task_id": t2]).text == "Removed: Second")
        #expect(call(s, "task_next", ["project": "Where"]).text == "Nothing waiting.")
    }

    @Test func resourcesLeaseRenewReleaseAndDeregister() throws {
        let s = try server()
        let a = id(after: "", in: call(s, "agent_register", ["name": "a"]).text)
        let b = id(after: "", in: call(s, "agent_register", ["name": "b"]).text)
        #expect(call(s, "resource_list").text.hasPrefix("No resources"))
        #expect(call(s, "resource_add", ["name": "iPhone", "max_minutes": 120]).text.hasPrefix("Defined iPhone: 1 slot"))
        #expect(call(s, "resource_add", ["name": "iphone"]).text.hasPrefix("Already defined"))

        #expect(call(s, "resource_lease", ["agent_id": a, "resource": "iPhone", "minutes": 30, "why": "capture"]).text.hasPrefix("Leased iPhone"))
        let full = call(s, "resource_lease", ["agent_id": b, "resource": "iPhone"])
        #expect(full.text.contains("is full (held by a)"))
        #expect(call(s, "resource_list").text.contains("0 of 1 free"))

        #expect(call(s, "resource_renew", ["agent_id": a, "resource": "iPhone", "minutes": 10]).text.hasPrefix("iPhone is yours until"))
        #expect(call(s, "resource_renew", ["agent_id": b, "resource": "iPhone"]).isError)
        #expect(call(s, "resource_release", ["agent_id": a, "resource": "iPhone"]).text == "Released iPhone.")
        #expect(call(s, "resource_lease", ["agent_id": b, "resource": "iPhone"]).text.hasPrefix("Leased iPhone"))

        #expect(call(s, "agent_deregister", ["agent_id": b]).text.contains("released 1 lease"))
        #expect(call(s, "resource_list").text.contains("1 of 1 free"))
        #expect(call(s, "resource_lease", ["agent_id": a, "resource": "Nothing"]).isError)
    }

    @Test func factoryStatusAndAsk() throws {
        let gb: UInt64 = 1_073_741_824
        let busy = MachineReading(memoryTotal: 32 * gb, memoryFree: 6 * gb, swapUsed: 3 * gb, swapTotal: 4 * gb, load: 2, cores: 10, compiles: 1, simulators: 0)
        let s = MCPServer(store: try temporaryStore(), pollInterval: 0.01, machine: { busy })
        let status = call(s, "factory_status").text
        #expect(status.hasPrefix("Over capacity."))
        #expect(status.contains("Compiles 1 of 5"))
        #expect(call(s, "factory_ask", ["work": "compile"]).text.hasPrefix("No:"))
        #expect(call(s, "factory_ask", ["work": "nothing"]).isError)

        try s.store.save(Throttle(compileSlots: 1, swapCeiling: 0.9, memoryFloor: 0.05))
        #expect(call(s, "factory_ask", ["work": "compile"]).text.hasPrefix("Wait: 1 of 1 compile slots"))
        #expect(call(s, "factory_ask", ["work": "simulator"]).text == "Yes.")

        let blind = MCPServer(store: try temporaryStore(), pollInterval: 0.01, machine: { nil })
        #expect(call(blind, "factory_status").isError)
    }

    @Test func errorsAreToolErrorsNotProtocolErrors() throws {
        let s = try server()
        let r = call(s, "agent_checkin", ["agent_id": "not-an-id"])
        #expect(r.isError)
        #expect(r.text.contains("agent_register"))
        #expect(call(s, "task_list", ["project": "Nowhere"]).isError)
        #expect(call(s, "nothing").isError)
    }
}

/// A clock that moves one second per look, so a timeout test needs no real waiting.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 0
    func tick() -> Date {
        lock.lock(); defer { lock.unlock() }
        t += 1
        return Date(timeIntervalSince1970: t)
    }
}
