import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct MCPServerTests {
    func server() throws -> MCPServer {
        MCPServer(store: try temporaryStore(), pollInterval: 0.01)
    }

    @Test func numbersAreShortUniqueAndUsableAsIds() throws {
        let s = try server()
        let first = call(s, "task_add", ["project": "/tmp/N", "title": "First"]).text
        #expect(first.hasSuffix(", T1"))
        // Someone matches an older numbering; the next task continues from it.
        #expect(call(s, "task_add", ["project": "/tmp/N", "title": "Old", "number": 509]).text.hasSuffix(", T509"))
        #expect(call(s, "task_add", ["project": "/tmp/N", "title": "Next"]).text.hasSuffix(", T510"))
        #expect(call(s, "task_add", ["project": "/tmp/N", "title": "Clash", "number": 509]).isError)
        #expect(call(s, "task_show", ["task_id": "T509"]).text.contains("Old"))
        #expect(call(s, "task_show", ["task_id": "509"]).text.contains("Old"))
        #expect(call(s, "task_number", ["task_id": "t1", "number": 354]).text == "First is T354.")
        #expect(call(s, "task_number", ["task_id": "T354", "number": 509]).isError)
        #expect(call(s, "task_rank", ["task_id": "T510", "above_task_id": "T354"]).text.contains("Next now sits above First"))
        #expect(call(s, "task_list", ["project": "N"]).text.hasPrefix("T510  "))
        // A removed task keeps its number: it is never given out again.
        _ = call(s, "task_remove", ["task_id": "T510"])
        #expect(call(s, "task_add", ["project": "/tmp/N", "title": "After"]).text.hasSuffix(", T511"))
    }

    @Test func aProjectCanBeRemovedOnceItsBacklogIsClear() throws {
        let s = try server()
        _ = call(s, "project_add", ["path": "/Users/alexcollins/Reserch"])
        let t = id(after: "task_id:", in: call(s, "task_add", ["project": "Reserch", "title": "stray"]).text).replacingOccurrences(of: ",", with: "")
        #expect(call(s, "project_remove", ["project": "Reserch"]).isError)
        _ = call(s, "task_status", ["task_id": t, "state": "done"])
        #expect(call(s, "project_remove", ["project": "Reserch", "reason": "typo"]).text.hasPrefix("Removed Reserch: typo"))
        #expect(!call(s, "project_list").text.contains("Reserch"))
        #expect(try s.store.load().tasks.isEmpty)
        #expect(try s.store.loadEveryTask().count == 1)
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

        // A note rides with the choice; an answer in the person's own words comes as such.
        try decided.decide(decided.options[1], note: "cache it for an hour", by: "alex")
        try s.store.save(decided)
        #expect(call(s, "escalation_await", ["escalation_id": escID, "timeout_seconds": 1]).text == "Decided by alex: Open-Meteo\nNote from alex: cache it for an hour")
        try decided.answer("Neither. Use the phone's own sensor.", by: "alex, phone")
        try s.store.save(decided)
        #expect(call(s, "escalation_await", ["escalation_id": escID, "timeout_seconds": 1]).text == "Answered by alex, phone in their own words, none of the options: Neither. Use the phone's own sensor.")

        let bye = call(s, "agent_deregister", ["agent_id": agentID])
        #expect(!bye.isError)
        #expect(try s.store.load().agents[0].deregistered != nil)
    }

    @Test func tasksRoundTrip() throws {
        let s = try server()
        let agentID = id(after: "", in: call(s, "agent_register", ["name": "a", "project": "/tmp/Where"]).text)
        let t1 = id(after: "", in: call(s, "task_add", ["project": "Where", "title": "First", "kind": "bug", "note": "the rooms run together\nsplit on pauses"]).text)
        let t2 = id(after: "", in: call(s, "task_add", ["project": "Where", "title": "Second"]).text)
        #expect(call(s, "task_next", ["project": "Where"]).text.contains("First"))
        #expect(call(s, "task_next", ["project": "Where"]).text.hasSuffix("note: the rooms run together\nsplit on pauses"))
        let t0 = id(after: "", in: call(s, "task_add", ["project": "Where", "title": "Urgent", "position": "top"]).text)
        #expect(call(s, "task_next", ["project": "Where"]).text.contains("Urgent"))
        #expect(call(s, "task_remove", ["task_id": t0, "reason": "a test"]).text.hasPrefix("Removed: Urgent"))
        #expect(try s.store.loadRemovedTasks().first?.note.contains("removed: a test") == true)
        let mid = id(after: "", in: call(s, "task_add", ["project": "Where", "title": "Middle", "above_task_id": t2]).text)
        let order = call(s, "task_list", ["project": "Where"]).text.split(separator: "\n").map { String($0.split(separator: "  ")[4]) }
        #expect(order == ["First", "Middle", "Second"])
        #expect(call(s, "task_status", ["task_id": mid, "state": "parked"]).text == "Middle: parked")
        #expect(call(s, "task_next", ["project": "Where"]).text.contains("First"))
        #expect(call(s, "task_remove", ["task_id": mid]).text.hasPrefix("Removed: Middle"))

        #expect(call(s, "task_rank", ["task_id": t2, "above_task_id": t1]).text.contains("Second now sits above First"))
        #expect(call(s, "task_next", ["project": "Where"]).text.contains("Second"))

        #expect(call(s, "task_claim", ["task_id": t1, "agent_id": agentID]).text == "You are on: First\nnote: the rooms run together\nsplit on pauses")
        let list = call(s, "task_list", ["project": "Where"]).text
        #expect(list.split(separator: "\n").first?.contains("inProgress  bug  First") == true)
        #expect(call(s, "task_note", ["task_id": t1, "text": "the tap runs off the main actor", "agent_id": agentID]).text == "Noted on First.")
        let shownNote = call(s, "task_show", ["task_id": t1]).text
        #expect(shownNote.contains(": the tap runs off the main actor") && shownNote.contains("inProgress"))

        #expect(call(s, "task_status", ["task_id": t1, "state": "done", "note": "fixed by splitting on pauses"]).text == "First: done")
        let snap = try s.store.load()
        #expect(snap.tasks.first { $0.title == "First" }?.note.hasSuffix("fixed by splitting on pauses") == true)

        #expect(call(s, "task_remove", ["task_id": t2]).text.hasPrefix("Removed: Second"))
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

    @Test func aQuestionFromATaskBlocksItUntilAnswered() throws {
        let s = try server()
        let a = id(after: "", in: call(s, "agent_register", ["name": "lead", "project": "/tmp/P"]).text)
        let t = id(after: "", in: call(s, "task_add", ["project": "P", "title": "Name the app", "kind": "review"]).text)
        let raised = call(s, "escalation_raise", ["agent_id": a, "project": "P", "task_id": t, "question": "Which name?",
                                                  "options": [["title": "A"], ["title": "B"]]])
        #expect(raised.text.contains("Name the app is blocked on it"))
        let escID = id(after: "", in: raised.text)
        var snap = try s.store.load()
        #expect(snap.tasks[0].state == .blocked)
        #expect(snap.tasks[0].blockers.first?.kind == .decision)
        #expect(snap.escalations[0].taskID == snap.tasks[0].id)
        #expect(call(s, "escalation_list", ["project": "P"]).text.contains("stops: Name the app"))
        #expect(call(s, "task_list", ["project": "P"]).text.contains("review"))

        var e = try #require(s.store.escalation(UUID(uuidString: escID)!))
        try e.decide(e.options[0], by: "alex")
        try s.store.save(e)
        snap = try s.store.load()
        let cleared = Sweep.unblocked(in: snap, now: .now)
        #expect(cleared.map(\.title) == ["Name the app"])
        #expect(cleared[0].note.contains("decided Which name? → A, by alex"))
        try s.store.save(cleared[0])
        // The decision is on the row where every reader sees it: the list's last line, and task_show.
        #expect(call(s, "task_list", ["project": "P"]).text.contains("— unblocked, decided Which name? → A, by alex"))
        let shown = call(s, "task_show", ["task_id": t]).text
        #expect(shown.contains("question \(escID): Which name? → A, by alex"))
        #expect(shown.contains("note: unblocked, decided"))
    }

    @Test func aProjectOnHoldHandsNothingOut() throws {
        let s = try server()
        _ = call(s, "task_add", ["project": "/tmp/P", "title": "Waiting"])
        var project = try #require(try s.store.load().projects.first)
        project.onHold = true
        try s.store.save(project)
        #expect(call(s, "task_next", ["project": "P"]).text.hasPrefix("P is on hold"))
        #expect(call(s, "project_list").text.contains("ON HOLD"))
        #expect(call(s, "agent_register", ["name": "a", "project": "/tmp/P"]).text.contains("P is on hold"))
        #expect(call(s, "task_list", ["project": "P"]).text.hasPrefix("P is ON HOLD"))
        let a = id(after: "", in: call(s, "agent_register", ["name": "b"]).text)
        let waiting = try #require(try s.store.load().tasks.first)
        #expect(call(s, "task_claim", ["task_id": waiting.id.uuidString, "agent_id": a]).text.hasPrefix("P is on hold: stop working"))
        #expect(try s.store.load().tasks.first?.state == .backlog)
        project.onHold = false
        try s.store.save(project)
        #expect(call(s, "task_next", ["project": "P"]).text.contains("Waiting"))
    }

    @Test func unblockOneAndMove() throws {
        let s = try server()
        _ = call(s, "agent_register", ["name": "a", "project": "/tmp/P"])
        _ = call(s, "project_add", ["path": "/tmp/Q"])
        let t = id(after: "", in: call(s, "task_add", ["project": "P", "title": "Stuck"]).text)
        _ = call(s, "task_block", ["task_id": t, "on": "other", "why": "the measurement"])
        _ = call(s, "task_block", ["task_id": t, "on": "person", "why": "the stand-down"])
        #expect(call(s, "task_unblock", ["task_id": t, "which": "measurement"]).text.hasPrefix("Cleared one. Stuck still waits on 1: the stand-down"))
        #expect(call(s, "task_unblock", ["task_id": t, "which": "nothing"]).isError)
        #expect(call(s, "task_unblock", ["task_id": t, "which": "1"]).text.hasPrefix("Cleared the last one."))
        #expect(call(s, "task_move", ["task_id": t, "project": "Q"]).text == "Moved Stuck to Q's backlog.")
        #expect(call(s, "task_list", ["project": "Q"]).text.contains("moved here from P"))
        #expect(call(s, "task_list", ["project": "P"]).text == "Nothing on the backlog.")
    }

    @Test func blockingATaskSaysWhatIsNext() throws {
        let s = try server()
        let a = id(after: "", in: call(s, "agent_register", ["name": "a", "project": "/tmp/P"]).text)
        let t1 = id(after: "", in: call(s, "task_add", ["project": "P", "title": "Needs Alex"]).text)
        _ = call(s, "task_add", ["project": "P", "title": "Free"])
        #expect(call(s, "task_block", ["task_id": t1, "on": "decision", "why": "x"]).isError)
        let blocked = call(s, "task_block", ["task_id": t1, "on": "person", "why": "register the container"])
        #expect(blocked.text.hasPrefix("Needs Alex is blocked on 1 thing. Next on the backlog: Free"))
        #expect(call(s, "task_block", ["task_id": t1, "on": "other", "why": "the measurement"]).text.hasPrefix("Needs Alex is blocked on 2 things."))
        #expect(call(s, "task_next", ["project": "P"]).text.contains("Free"))
        #expect(call(s, "task_list", ["project": "P"]).text.contains("blocked on person: register the container; other: the measurement"))
        _ = a
    }

    @Test func anyCallIsAHeartbeat() throws {
        let clock = Clock()
        let s = MCPServer(store: try temporaryStore(), now: { clock.tick() }, pollInterval: 0)
        let a = id(after: "", in: call(s, "agent_register", ["name": "a", "project": "/tmp/P"]).text)
        let seen0 = try #require(try s.store.load().agents.first).lastSeen
        _ = call(s, "task_add", ["project": "P", "title": "t"])
        let t = try #require(try s.store.load().tasks.first).id.uuidString
        _ = call(s, "task_claim", ["task_id": t, "agent_id": a])
        let seen1 = try #require(try s.store.load().agents.first).lastSeen
        #expect(seen1 > seen0)
        _ = call(s, "task_status", ["task_id": t, "state": "done"])       // no agent_id: not a heartbeat
        let seen2 = try #require(try s.store.load().agents.first).lastSeen
        #expect(seen2 == seen1)
    }

    @Test func anOldCheckInStillCounts() throws {
        let s = try server()
        let a = id(after: "", in: call(s, "agent_register", ["name": "old"]).text)
        let r = call(s, "agent_checkin", ["agent_id": a])
        #expect(!r.isError)
        #expect(r.text.hasPrefix("Noted."))
        #expect(!call(s, "agent_checkin", ["agent_id": "nope"]).isError == false)
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
        let r = call(s, "task_claim", ["agent_id": "not-an-id", "task_id": UUID().uuidString])
        #expect(r.isError)
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
