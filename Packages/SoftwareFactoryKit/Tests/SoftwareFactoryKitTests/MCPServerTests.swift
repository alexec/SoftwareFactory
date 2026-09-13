import Foundation
import Testing
@testable import SoftwareFactoryKit

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?

    func set(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        self.text = text
    }

    func value() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

@Suite struct MCPServerTests {
    func server() throws -> MCPServer {
        MCPServer(store: try temporaryStore(), pollInterval: 0.01)
    }

    @Test func taskNextSkipsParkedTasks() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "Parked Test", "description": "Parked task test."])
        _ = call(s, "task_add", ["project": "Parked Test", "title": "Set aside", "position": "parked"])
        _ = call(s, "task_add", ["project": "Parked Test", "title": "Available"])
        #expect(call(s, "task_list", ["project": "Parked Test"]).text.contains(" parked "))
        #expect(call(s, "task_next", ["project": "Parked Test"]).text.contains("Available"))
    }

    @Test func numbersAreShortUniqueAndUsableAsIds() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "N", "description": "Numbering test."])
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
        #expect(call(s, "project_add", ["name": "Reserch", "description": "Temporary project."]).text.hasPrefix("Reserch  "))
        let t = id(after: "task_id:", in: call(s, "task_add", ["project": "Reserch", "title": "stray"]).text).replacingOccurrences(of: ",", with: "")
        #expect(call(s, "project_remove", ["project": "Reserch"]).isError)
        _ = call(s, "task_status", ["task_id": t, "state": "done"])
        #expect(call(s, "project_remove", ["project": "Reserch", "reason": "typo"]).text.hasPrefix("Removed Reserch: typo"))
        #expect(!call(s, "project_list").text.contains("Reserch"))
        #expect(try s.store.load().tasks.isEmpty)
        #expect(try s.store.loadEveryTask().count == 1)
    }

    @Test func aProjectCanBeGivenAFolderAndItCanBeCleared() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "Widget", "description": "Widget work.", "folder": "/tmp/Widget"])
        #expect(try s.store.load().projects.first { $0.name == "Widget" }?.path == "/tmp/Widget")
        #expect(call(s, "project_set_path", ["project": "Widget", "path": "/tmp/Widget2"]).text == "Widget runs in /tmp/Widget2.")
        #expect(try s.store.load().projects.first { $0.name == "Widget" }?.path == "/tmp/Widget2")
        #expect(call(s, "project_set_path", ["project": "Widget", "path": ""]).text == "Widget has no folder now.")
        #expect(try s.store.load().projects.first { $0.name == "Widget" }?.path == nil)
    }

    @Test func projectDescriptionsAndInstructionsGuideAgents() throws {
        let s = try server()
        #expect(call(s, "task_add", ["project": "Missing", "title": "No project"]).isError)
        #expect(call(s, "project_add", ["name": "Guided"]).isError)
        #expect(!call(s, "project_add", [
            "name": "Guided", "description": "Work that needs the factory guide.",
            "instructions": "Read the guide before starting.",
        ]).isError)
        #expect(call(s, "project_list").text.contains("Work that needs the factory guide."))
        #expect(call(s, "project_set", [
            "project": "Guided", "set_description": "Guided factory work.",
        ]).text == "Guided description is updated.")
        let agentID = id(after: "agent_id:", in: call(s, "agent_register", ["project": "Guided"]).text)
        let blocked = call(s, "task_add", ["project": "Guided", "title": "Read the guide", "agent_id": agentID])
        #expect(blocked.isError)
        #expect(blocked.text == "You must first call project_get for Guided and read its instructions before creating or modifying a task.")
        let project = call(s, "project_get", ["project": "Guided", "agent_id": agentID]).text
        #expect(project.contains("name: Guided"))
        #expect(project.contains("description: Guided factory work."))
        #expect(project.contains("instructions: Read the guide before starting."))
        let projectID = try #require(s.store.load().projects.first { $0.name == "Guided" }?.id)
        #expect(try s.store.load().agents.first { $0.label == agentID }?.seenInstructions[projectID] == "Read the guide before starting.")
        #expect(!call(s, "task_list", ["project": "Guided", "agent_id": agentID]).text.contains("instructions:"))
        #expect(!call(s, "task_add", ["project": "Guided", "title": "Read the guide", "agent_id": agentID]).isError)
        #expect(call(s, "project_set", [
            "project": "Guided", "instructions": "Read the revised guide.",
        ]).text == "Guided instructions are updated.")
        #expect(call(s, "task_note", ["task_id": "T1", "text": "Updated", "agent_id": agentID]).isError)
        #expect(call(s, "project_get", ["project": "Guided", "agent_id": agentID]).text.contains("Read the revised guide."))
        #expect(!call(s, "task_note", ["task_id": "T1", "text": "Updated", "agent_id": agentID]).isError)
        #expect(call(s, "project_set", [
            "project": "Guided", "instructions": "",
        ]).text == "Guided instructions are cleared.")
    }

    /// Naming a project nobody has used makes it. An agent whose work belongs to no
    /// project registers without one. (Alex, 12 Sep 2026: it is allowed.)
    @Test func registeringNamesTheProjectOrNone() throws {
        let s = try server()
        let a = id(after: "", in: call(s, "agent_register", ["project": "Brand New"]).text)
        let agent = try #require(try s.store.load().agents.first { $0.label == a })
        let project = try #require(try s.store.load().projects.first { $0.id == agent.projectID })
        #expect(project.name == "Brand New")

        let loose = id(after: "", in: call(s, "agent_register", ["about": "Works across everything"]).text)
        #expect(try s.store.load().agents.first { $0.label == loose }?.projectID == nil)
        // Registering again without one keeps the project it already had.
        _ = call(s, "agent_register", ["agent_id": a, "about": "Still here"])
        #expect(try s.store.load().agents.first { $0.label == a }?.projectID == project.id)
    }

    /// An agent is its A<n> and nothing else: registration takes no name, a name sent
    /// anyway is ignored, and nothing the factory says back carries one.
    /// (A9, 13 Sep 2026: T137.)
    @Test func anAgentIsOnlyItsNumber() throws {
        let s = try server()
        let registration = try #require(MCPServer.Tool.all.first { $0.name == "agent_register" })
        #expect(registration.properties["name"] == nil)

        _ = call(s, "project_add", ["name": "Named", "description": "Work for named agents."])
        let a = id(after: "", in: call(s, "agent_register", ["name": "lead", "project": "Named"]).text)
        let stored = try #require(try s.store.load().agents.first { $0.label == a })
        #expect(stored.name == a)

        // A second agent, so the first has someone to read about.
        let b = id(after: "", in: call(s, "agent_register", ["name": "hand", "about": "Builds it", "project": "Named"]).text)
        let listed = call(s, "agent_list", ["agent_id": a]).text
        #expect(listed.contains(b))
        #expect(!listed.lowercased().contains("hand"))
        // One name per agent on the line, not the label and a name beside it.
        #expect(!listed.contains("\(b)  \(b)"))

        // And on the task it is given, and in the comment that records the giving.
        _ = call(s, "project_get", ["project": "Named", "agent_id": a])
        _ = call(s, "task_add", ["project": "Named", "title": "Do it", "agent_id": a])
        _ = call(s, "task_set", ["task_id": "T1", "assign_to": b, "agent_id": a])
        let task = call(s, "task_list", ["task_id": "T1", "agent_id": a]).text
        #expect(task.contains("agent: \(b)"))
        #expect(!task.lowercased().contains("hand"))
    }

    @Test func anAgentUpdatesItsRegistrationInTheSameSession() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "P", "description": "Project P."])
        let a = id(after: "", in: call(s, "agent_register", ["name": "lead", "project": "P"]).text)
        let registration = try #require(MCPServer.Tool.all.first { $0.name == "agent_register" })
        let again = call(s, "agent_register", ["agent_id": a, "project": "P"]).text
        #expect(again == "Registered. agent_id: \(a)")
        #expect(try s.store.load().agents.count == 1)
    }

    /// The app starts an agent in a terminal session and sets SOFTWARE_FACTORY_SESSION;
    /// the agent hands that back at registration so the app can show it working.
    @Test func anAgentRegistersTheSessionItWasStartedIn() throws {
        let s = try server()
        let a = id(after: "", in: call(s, "agent_register", ["project": "Sessions", "session": "sf-1234"]).text)
        #expect(try s.store.load().agents.first { $0.label == a }?.session == "sf-1234")
        // Registering again without one keeps the session it already has.
        _ = call(s, "agent_register", ["agent_id": a, "project": "Sessions"])
        #expect(try s.store.load().agents.first { $0.label == a }?.session == "sf-1234")
        // An agent started by hand has none.
        let byHand = id(after: "", in: call(s, "agent_register", ["project": "Sessions"]).text)
        #expect(try s.store.load().agents.first { $0.label == byHand }?.session == nil)
    }

    /// Every tool that waits waits the same way: the same timeout_seconds, and an
    /// answer telling you to call again rather than an error.
    /// An agent that has read the backlog can take several tasks that are one piece of
    /// work, rather than being handed them one at a time.
    @Test func severalTasksCanBeClaimedTogether() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "Together", "description": "Work that belongs together."])
        _ = call(s, "task_add", ["project": "Together", "title": "Rename the type"])
        _ = call(s, "task_add", ["project": "Together", "title": "Rename its file"])
        _ = call(s, "task_add", ["project": "Together", "title": "Something else"])
        let a = id(after: "", in: call(s, "agent_register", ["project": "Together"]).text)
        _ = call(s, "project_get", ["project": "Together", "agent_id": a])

        let claimed = call(s, "task_claim", ["agent_id": a, "task_ids": ["T1", "T2"]])
        #expect(!claimed.isError)
        #expect(claimed.text.contains("Rename the type") && claimed.text.contains("Rename its file"))
        let snap = try s.store.load()
        let mine = snap.tasks.filter { $0.state == .inProgress }
        #expect(Set(mine.map(\.title)) == ["Rename the type", "Rename its file"])
        #expect(mine.allSatisfy { $0.agentID == snap.agents.first { $0.label == a }?.id })
        // The third is still waiting, and one id on its own still works.
        #expect(call(s, "task_next", ["project": "Together", "timeout_seconds": 0]).text.contains("Something else"))
        #expect(!call(s, "task_claim", ["agent_id": a, "task_id": "T3"]).isError)
        #expect(call(s, "task_claim", ["agent_id": a]).isError)
    }

    /// A query reads and nothing else. Run every one against a factory with work in it
    /// and the store is untouched afterwards, byte for byte.
    @Test func queriesNeverWrite() throws {
        // A clock that moves a minute every time it is read, so a heartbeat written
        // during a query cannot hide inside the same second.
        let clock = Clock()
        let s = MCPServer(store: try temporaryStore(), now: { clock.tick() }, pollInterval: 0.01)
        _ = call(s, "project_add", ["name": "Q", "description": "A project to read."])
        let a = id(after: "", in: call(s, "agent_register", ["project": "Q"]).text)
        _ = call(s, "project_read", ["project": "Q", "agent_id": a])
        _ = call(s, "task_add", ["project": "Q", "title": "Something to read", "agent_id": a])
        _ = call(s, "escalation_raise", ["agent_id": a, "project": "Q", "question": "Which?",
                                        "options": [["title": "A"], ["title": "B"]]])
        _ = call(s, "resource_add", ["name": "iPhone", "agent_id": a])

        for tool in MCPServer.Tool.all where tool.kind == .query {
            let before = try fingerprint(of: s.store)
            var args: [String: Any] = ["agent_id": a, "timeout_seconds": 0]
            if tool.name == "task_next" || tool.name == "task_list" { args["project"] = "Q" }
            if tool.name == "escalation_await" { args["escalation_id"] = UUID().uuidString }
            if tool.name == "factory_ask" { args["work"] = "compile" }
            _ = call(s, tool.name, args)
            #expect(try fingerprint(of: s.store) == before, "\(tool.name) wrote to the store")
        }
        // The control: a command does change it, so the check above means something.
        let before = try fingerprint(of: s.store)
        _ = call(s, "task_note", ["agent_id": a, "task_id": "T1", "text": "a line"])
        #expect(try fingerprint(of: s.store) != before)
    }

    /// Every file in the store, with what it holds, apart from the heartbeat: a call is
    /// a sign of life whatever it asks for, and that is the only write a query may do.
    private func fingerprint(of store: FileStore) throws -> [String: String] {
        var out: [String: String] = [:]
        let files = FileManager.default.enumerator(at: store.root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "json" else { continue }
            var text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            text = text.replacingOccurrences(
                of: #""lastSeen"\s*:\s*"[^"]*""#, with: #""lastSeen":"-""#, options: .regularExpression)
            out[url.lastPathComponent] = text
        }
        return out
    }

    @Test func waitingToolsShareOneShape() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "W", "description": "Waiting."])
        let a = id(after: "", in: call(s, "agent_register", ["project": "W"]).text)

        #expect(call(s, "task_next", ["project": "W", "timeout_seconds": 0]).text == "Nothing waiting. Call task_next again.")
        #expect(call(s, "inbox", ["agent_id": a, "wait": true, "timeout_seconds": 0]).text
            == "No new messages. Call inbox again with wait: true.")
        let raised = call(s, "escalation_raise", ["agent_id": a, "project": "W", "question": "Which?",
                                                 "options": [["title": "A"], ["title": "B"]]])
        let escalation = id(after: "", in: raised.text)
        #expect(call(s, "escalation_await", ["escalation_id": escalation, "timeout_seconds": 0]).text
            == "Still open. Call escalation_await again.")
        // None of them is an error: the agent is meant to come back.
        #expect(!call(s, "task_next", ["project": "W", "timeout_seconds": 0]).isError)
        // And every one of them takes the same argument.
        for tool in ["task_next", "inbox", "escalation_await"] {
            let defined = try #require(MCPServer.Tool.all.first { $0.name == tool })
            #expect(defined.properties["timeout_seconds"] != nil)
        }
    }

    @Test func agentsCanDescribeThemselvesAndSendMail() throws {
        let s = try server()
        let lead = id(after: "", in: call(s, "agent_register", ["project": "Mail", "about": "Coordinates the work."]).text)
        let worker = id(after: "", in: call(s, "agent_register", ["project": "Mail", "about": "Builds the app."]).text)

        let listed = call(s, "agent_list", ["agent_id": lead]).text
        #expect(listed.contains(worker) && listed.contains("Builds the app."))
        #expect(!listed.contains(lead))
        #expect(try s.store.load().agents.first { $0.label == worker }?.about == "Builds the app.")

        #expect(call(s, "agent_message_send", [
            "agent_id": lead, "to_agent_id": worker, "subject": "Please review", "contents": "Start with the MCP server.",
        ]).text == "Sent to \(worker).")
        let inbox = call(s, "agent_messages", ["agent_id": worker]).text
        #expect(inbox.contains("from: \(lead)") && inbox.contains("subject: Please review") && inbox.contains("contents:\nStart with the MCP server."))
        #expect(call(s, "agent_message_send", [
            "agent_id": lead, "to_agent_id": lead, "subject": "No", "contents": "No",
        ]).isError)
    }

    @Test func agentMessagesCanWaitForNewMail() throws {
        let s = try server()
        let sender = id(after: "", in: call(s, "agent_register", ["project": "P"]).text)
        let receiver = id(after: "", in: call(s, "agent_register", ["project": "P"]).text)
        _ = call(s, "agent_message_send", [
            "agent_id": sender, "to_agent_id": receiver, "subject": "Earlier", "contents": "Already here.",
        ])

        let completed = DispatchSemaphore(value: 0)
        let result = ResultBox()
        DispatchQueue.global().async {
            result.set(self.call(s, "agent_messages", ["agent_id": receiver, "wait_for_new": true, "timeout_seconds": 1]).text)
            completed.signal()
        }

        Thread.sleep(forTimeInterval: 0.05)
        #expect(completed.wait(timeout: .now()) == .timedOut)
        _ = call(s, "agent_message_send", [
            "agent_id": sender, "to_agent_id": receiver, "subject": "New", "contents": "This wakes the wait.",
        ])
        #expect(completed.wait(timeout: .now() + 1) == .success)
        #expect(result.value()?.contains("subject: New") == true)
        #expect(result.value()?.contains("subject: Earlier") == false)
    }

    @Test func aNearMissProjectNameIsRefusedRatherThanMadeTwice() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "Sleeper Train", "description": "Train work."])
        _ = call(s, "project_add", ["name": "Out of Mind", "description": "Other work."])
        #expect(Projects.nearMiss("NightSleeper", in: try s.store.load().projects)?.name == "Sleeper Train")
        #expect(Projects.nearMiss("sleeper-train", in: try s.store.load().projects) == nil)   // that one is exact
        #expect(Projects.exact("sleeper-train", in: try s.store.load().projects)?.name == "Sleeper Train")
        #expect(Projects.nearMiss("Walkist", in: try s.store.load().projects) == nil)
        let refused = call(s, "agent_register", ["name": "lead", "project": "NightSleeper"])
        #expect(refused.isError && refused.text.contains("there is Sleeper Train"))
        #expect(call(s, "task_add", ["project": "Sleeper", "title": "x"]).isError)
        #expect(call(s, "project_add", ["name": "Sleepers", "description": "Sleep work."]).isError)
        #expect(!call(s, "project_add", ["name": "Sleepers", "description": "Sleep work.", "force": true]).isError)
        #expect(!call(s, "agent_register", ["name": "lead", "project": "Walkist"]).isError)
        #expect(try s.store.load().projects.count == 4)
    }

    func call(_ s: MCPServer, _ tool: String, _ args: [String: Any] = [:], id: Int = 1) -> (text: String, isError: Bool) {
        let sessionID = (args["agent_id"] as? String) ?? UUID().uuidString
        let response = s.handle(["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                 "params": ["name": tool, "arguments": args]], agentID: sessionID)!
        let result = response["result"] as! [String: Any]
        let content = result["content"] as! [[String: Any]]
        return (content[0]["text"] as! String, result["isError"] as! Bool)
    }

    /// Registration without a connection behind it, as a fresh MCP session makes it: the
    /// agent's own agent_id is all there is to go on.
    func register(_ s: MCPServer, _ args: [String: Any] = [:], bound: String? = nil) -> (text: String, isError: Bool) {
        let response = s.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                 "params": ["name": "agent_register", "arguments": args]], agentID: bound)!
        let result = response["result"] as! [String: Any]
        let content = result["content"] as! [[String: Any]]
        return (content[0]["text"] as! String, result["isError"] as! Bool)
    }

    /// The app writes an agent down before it starts it and tells it its name. Asking for
    /// that name gets that record, card, terminal and all, rather than the next number.
    /// (Alex, 13 Sep 2026: it registers as A<n> and becomes A<n+1>.)
    @Test func anAgentGetsTheNameItWasTold() throws {
        let s = try server()
        let reserved = Agents.reserve(number: try s.store.takeAgentNumber(), projectID: nil, session: "sf-abcd")
        try s.store.save(reserved)
        #expect(reserved.label == "A1")

        let out = register(s, ["agent_id": "A1", "about": "Engineer"])
        #expect(!out.isError)
        #expect(out.text.contains("agent_id: A1"))
        let agents = try s.store.load().agents
        #expect(agents.count == 1)
        #expect(agents[0].id == reserved.id && agents[0].about == "Engineer" && agents[0].session == "sf-abcd")
    }

    /// A name a live session is working as is not there for the taking.
    @Test func aNameInUseIsRefused() throws {
        let s = try server()
        #expect(register(s).text.contains("agent_id: A1"))
        let out = register(s, ["agent_id": "A1"])
        #expect(out.isError)
        #expect(out.text.contains("A1 is taken"))
        // And nobody was quietly made instead.
        #expect(try s.store.load().agents.count == 1)
    }

    /// Its own name on its own connection is not a clash: that is the same agent saying
    /// something new about itself.
    @Test func anAgentMayRegisterAgainAsItself() throws {
        let s = try server()
        #expect(register(s, ["about": "First"]).text.contains("agent_id: A1"))
        let again = register(s, ["agent_id": "A1", "about": "Second"], bound: "A1")
        #expect(!again.isError)
        let agents = try s.store.load().agents
        #expect(agents.count == 1 && agents[0].about == "Second")
    }

    /// A name nobody has ever had is free for the asking, and the counter moves past it
    /// so the next agent along does not land on it.
    @Test func anUnusedNameMayBeClaimed() throws {
        let s = try server()
        #expect(register(s, ["agent_id": "A9"]).text.contains("agent_id: A9"))
        #expect(register(s).text.contains("agent_id: A10"))
    }

    /// A number that has been given out before stays spent, even once its agent is gone.
    @Test func aSpentNameIsRefusedEvenWhenItsAgentHasGone() throws {
        let s = try server()
        #expect(register(s).text.contains("agent_id: A1"))
        let gone = try s.store.load().agents[0]
        try s.store.delete(gone)
        let out = register(s, ["agent_id": "A1"])
        #expect(out.isError)
        #expect(out.text.contains("given out before"))
    }

    /// An agent_id that is no name at all, as an old client sends, is nothing to go on:
    /// the factory names it rather than refusing it.
    @Test func anIdThatIsNoNameIsIgnored() throws {
        let s = try server()
        let out = register(s, ["agent_id": UUID().uuidString])
        #expect(!out.isError)
        #expect(out.text.contains("agent_id: A1"))
    }

    /// Two agents never bind to one terminal: the second to say it is in that window
    /// takes it, and the first record loses it.
    @Test func onlyOneAgentHoldsATerminalSession() throws {
        let clock = Clock()
        let s = MCPServer(store: try temporaryStore(), now: { clock.now }, pollInterval: 0)
        #expect(register(s, ["session": "sf-abcd"]).text.contains("agent_id: A1"))
        // The first agent's shell exits; an hour later someone starts another in that
        // window, and it still has SOFTWARE_FACTORY_SESSION exported.
        clock.advance(by: 3600)
        #expect(register(s, ["session": "sf-abcd"]).text.contains("agent_id: A2"))

        let agents = try s.store.load().agents.sorted { ($0.number ?? 0) < ($1.number ?? 0) }
        #expect(agents.count == 2)
        #expect(agents[0].session == nil)
        #expect(agents[1].session == "sf-abcd")
        #expect(agents.filter { $0.session == "sf-abcd" }.count == 1)
    }

    /// While the first one is still working in there, the newcomer gets no window at all
    /// rather than one that is not its own.
    @Test func aWindowWithSomeoneWorkingInItIsNotHandedOver() throws {
        let s = try server()
        #expect(register(s, ["session": "sf-abcd"]).text.contains("agent_id: A1"))
        #expect(register(s, ["session": "sf-abcd"]).text.contains("agent_id: A2"))
        let agents = try s.store.load().agents.sorted { ($0.number ?? 0) < ($1.number ?? 0) }
        #expect(agents[0].session == "sf-abcd")
        #expect(agents[1].session == nil)
    }

    func id(after prefix: String, in text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }.first {
            ($0.first == "A" && Int($0.dropFirst()) != nil) || UUID(uuidString: $0) != nil
        } ?? ""
    }

    @Test func taskNextWaitsForNewBacklogWork() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "Waiting", "description": "Waiting work."])
        let completed = DispatchSemaphore(value: 0)
        let result = ResultBox()
        DispatchQueue.global().async {
            result.set(self.call(s, "task_next", ["project": "Waiting"]).text)
            completed.signal()
        }

        Thread.sleep(forTimeInterval: 0.05)
        #expect(completed.wait(timeout: .now()) == .timedOut)
        _ = call(s, "task_add", ["project": "Waiting", "title": "Arrived"])
        #expect(completed.wait(timeout: .now() + 1) == .success)
        #expect(result.value()?.contains("Arrived") == true)
    }

    @Test func taskNextReapsTheOldestWaiterAtTheConnectionLimit() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "Limited", "description": "Limited work."])
        let firstFinished = DispatchSemaphore(value: 0)
        let firstResult = ResultBox()
        DispatchQueue.global().async {
            firstResult.set(self.call(s, "task_next", ["project": "Limited"]).text)
            firstFinished.signal()
        }

        Thread.sleep(forTimeInterval: 0.05)
        let others = DispatchGroup()
        for _ in 0..<MCPServer.maximumWaitingTasks {
            others.enter()
            DispatchQueue.global().async {
                _ = self.call(s, "task_next", ["project": "Limited"])
                others.leave()
            }
        }

        #expect(firstFinished.wait(timeout: .now() + 1) == .success)
        #expect(firstResult.value()?.contains("Factory needs this connection") == true)
        _ = call(s, "task_add", ["project": "Limited", "title": "Arrived"])
        #expect(others.wait(timeout: .now() + 1) == .success)
    }

    @Test func handshakeAndToolList() throws {
        let s = try server()
        let init_ = s.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                              "params": ["protocolVersion": "2025-03-26", "capabilities": [:]]])!
        let result = init_["result"] as! [String: Any]
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "software-factory")
        // The one thing task_next and task_claim don't make obvious on their own: a
        // parked task is set aside on purpose, not an agent's to start.
        #expect((result["instructions"] as? String ?? "").contains("parked"))

        #expect(s.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)

        let list = s.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])!
        let tools = (list["result"] as! [String: Any])["tools"] as! [[String: Any]]
        let names = tools.map { $0["name"] as! String }
        #expect(names.contains("escalation_raise"))
        #expect(names.contains("escalation_await"))
        #expect(names.contains("agent_register"))
        #expect(names.contains("agent_deregister"))
        #expect(names.allSatisfy { $0.allSatisfy { $0.isLetter || $0 == "_" } })
        // The connection says who is calling, so no tool asks for agent_id. Registration
        // is the one exception: an agent the app started is told the name to ask for.
        #expect(tools.allSatisfy {
            let schema = $0["inputSchema"] as! [String: Any]
            let properties = schema["properties"] as! [String: Any]
            return properties["agent_id"] == nil || ($0["name"] as! String) == "agent_register"
        })

        // Every tool normally takes a call description, so the transcript can show what
        // it is doing rather than the bare tool name. Project creation and editing use
        // that field for the project's actual description instead.
        for tool in tools {
            let schema = tool["inputSchema"] as! [String: Any]
            let properties = schema["properties"] as! [String: Any]
            let name = tool["name"] as! String
            #expect(properties["description"] != nil, "\(name) has no description")
            let required = schema["required"] as! [String]
            if ["project_add", "project_set_description"].contains(name) {
                #expect(required.contains("description"))
            } else {
                #expect(!required.contains("description"))
            }
        }

        let unknown = s.handle(["jsonrpc": "2.0", "id": 3, "method": "nope"])!
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func theNarrowSlice() throws {
        let s = try server()
        let reg = call(s, "agent_register", ["name": "packed-lead", "project": "/tmp/Packed"])
        #expect(!reg.isError)
        let agentID = id(after: "agent_id:", in: reg.text)
        #expect(agentID == "A1")

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
        #expect(e.raisedBy == agentID)
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
        let t1 = id(after: "", in: call(s, "task_add", ["project": "Where", "title": "First", "note": "the rooms run together\nsplit on pauses"]).text)
        let t2 = id(after: "", in: call(s, "task_add", ["project": "Where", "title": "Second"]).text)
        #expect(call(s, "task_next", ["project": "Where"]).text.contains("First"))
        #expect(call(s, "task_next", ["project": "Where"]).text.hasSuffix("note: the rooms run together\nsplit on pauses"))
        let t0 = id(after: "", in: call(s, "task_add", ["project": "Where", "title": "Urgent", "position": "top"]).text)
        #expect(call(s, "task_next", ["project": "Where"]).text.contains("Urgent"))
        #expect(call(s, "task_remove", ["task_id": t0, "reason": "a test"]).text.hasPrefix("Removed: Urgent"))
        #expect(try s.store.loadRemovedTasks().first?.note.contains("removed: a test") == true)
        let mid = id(after: "", in: call(s, "task_add", ["project": "Where", "title": "Middle", "above_task_id": t2]).text)
        let order = call(s, "task_list", ["project": "Where"]).text.split(separator: "\n").map { String($0.split(separator: "  ")[3]) }
        #expect(order == ["First", "Middle", "Second"])
        #expect(call(s, "task_status", ["task_id": mid, "state": "parked"]).text == "Middle: parked")
        #expect(call(s, "task_next", ["project": "Where"]).text.contains("First"))
        #expect(call(s, "task_remove", ["task_id": mid]).text.hasPrefix("Removed: Middle"))

        #expect(call(s, "task_rank", ["task_id": t2, "above_task_id": t1]).text.contains("Second now sits above First"))
        #expect(call(s, "task_next", ["project": "Where"]).text.contains("Second"))

        _ = call(s, "project_get", ["project": "Where", "agent_id": agentID])
        #expect(call(s, "task_claim", ["task_id": t1, "agent_id": agentID]).text.hasPrefix("You are on: First\nnote: the rooms run together\nsplit on pauses"))
        let list = call(s, "task_list", ["project": "Where"]).text
        #expect(list.split(separator: "\n").first?.contains("inProgress  First") == true)
        #expect(call(s, "task_note", ["task_id": t1, "text": "the tap runs off the main actor", "agent_id": agentID]).text.hasPrefix("Noted on First."))
        let shownNote = call(s, "task_show", ["task_id": t1]).text
        #expect(shownNote.contains(": the tap runs off the main actor") && shownNote.contains("inProgress"))

        let completed = call(s, "task_status", ["task_id": t1, "state": "done", "note": "fixed by splitting on pauses"]).text
        #expect(completed.hasPrefix("First: done\nNext on the backlog: "))
        #expect(completed.contains("Second") && completed.hasSuffix("\nYou should work on this next."))
        #expect(try s.store.load().agents.first?.taskID == nil)
        let snap = try s.store.load()
        #expect(snap.tasks.first { $0.title == "First" }?.note.hasSuffix("fixed by splitting on pauses") == true)

        #expect(call(s, "task_remove", ["task_id": t2]).text.hasPrefix("Removed: Second"))
        let emptied = try s.store.load()
        let project = try #require(emptied.projects.first)
        #expect(Backlog.next(for: project.id, in: emptied.tasks) == nil)
    }

    @Test func finishingOneOfSeveralAssignmentsDoesNotSuggestAnotherTask() throws {
        let s = try server()
        let agentID = id(after: "", in: call(s, "agent_register", ["name": "a", "project": "P"]).text)
        let first = id(after: "", in: call(s, "task_add", ["project": "P", "title": "First"]).text)
        let next = id(after: "", in: call(s, "task_add", ["project": "P", "title": "Next"]).text)
        let other = id(after: "", in: call(s, "task_add", ["project": "P", "title": "Other"]).text)
        _ = call(s, "project_get", ["project": "P", "agent_id": agentID])
        _ = call(s, "task_claim", ["task_id": first, "agent_id": agentID])
        _ = call(s, "task_claim", ["task_id": other, "agent_id": agentID])

        #expect(call(s, "task_status", ["task_id": first, "state": "done"]).text == "First: done")
        #expect(try s.store.load().agents.first?.taskID == UUID(uuidString: other))
        #expect(try s.store.load().tasks.first { $0.id == UUID(uuidString: next) }?.state == .backlog)
    }

    @Test func resourcesLeaseRenewReleaseAndDeregister() throws {
        let s = try server()
        let a = id(after: "", in: call(s, "agent_register", ["project": "Shared"]).text)
        let b = id(after: "", in: call(s, "agent_register", ["project": "Shared"]).text)
        #expect(call(s, "resource_list").text.hasPrefix("No resources"))
        #expect(call(s, "resource_add", ["name": "iPhone", "max_minutes": 120]).text.hasPrefix("Defined iPhone: 1 slot"))
        #expect(call(s, "resource_add", ["name": "iphone"]).text.hasPrefix("Already defined"))

        #expect(call(s, "resource_lease", ["agent_id": a, "resource": "iPhone", "minutes": 30, "why": "capture"]).text.hasPrefix("Leased iPhone"))
        let full = call(s, "resource_lease", ["agent_id": b, "resource": "iPhone"])
        #expect(full.text.contains("is full (held by \(a))"))
        #expect(call(s, "resource_list").text.contains("0 of 1 free"))

        #expect(call(s, "resource_lease", ["agent_id": a, "resource": "iPhone", "minutes": 10]).text.hasPrefix("Leased iPhone until"))
        #expect(call(s, "resource_lease", ["agent_id": b, "resource": "iPhone"]).text.contains("is full"))
        #expect(call(s, "resource_release", ["agent_id": a, "resource": "iPhone"]).text.hasPrefix("Released iPhone."))
        #expect(call(s, "resource_lease", ["agent_id": b, "resource": "iPhone"]).text.hasPrefix("Leased iPhone"))

        #expect(call(s, "agent_deregister", ["agent_id": b]).text.contains("released 1 lease"))
        #expect(call(s, "resource_list").text.contains("1 of 1 free"))
        #expect(call(s, "resource_lease", ["agent_id": a, "resource": "Nothing"]).isError)
    }

    @Test func aQuestionFromATaskBlocksItUntilAnswered() throws {
        let s = try server()
        let a = id(after: "", in: call(s, "agent_register", ["name": "lead", "project": "/tmp/P"]).text)
        let t = id(after: "", in: call(s, "task_add", ["project": "P", "title": "Name the app"]).text)
        _ = call(s, "project_get", ["project": "P", "agent_id": a])
        let raised = call(s, "escalation_raise", ["agent_id": a, "project": "P", "task_id": t, "question": "Which name?",
                                                  "options": [["title": "A"], ["title": "B"]]])
        #expect(raised.text.contains("Name the app is blocked on it"))
        let escID = id(after: "", in: raised.text)
        var snap = try s.store.load()
        #expect(snap.tasks[0].state == .blocked)
        #expect(snap.tasks[0].blockers.first?.kind == .decision)
        #expect(snap.escalations[0].taskID == snap.tasks[0].id)
        #expect(call(s, "escalation_list", ["project": "P"]).text.contains("stops: Name the app"))
        #expect(call(s, "task_list", ["project": "P"]).text.contains("blocked on decision: Which name?"))

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

    @Test func aProjectOnHoldWarnsButBlocksNothing() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "P", "description": "Hold test."])
        _ = call(s, "task_add", ["project": "/tmp/P", "title": "Waiting"])
        var project = try #require(try s.store.load().projects.first)
        project.onHold = true
        try s.store.save(project)
        // On hold blocks nothing: the task is still handed out, with the warning after it.
        let next = call(s, "task_next", ["project": "P"]).text
        #expect(next.contains("Waiting") && next.contains("WARNING: P is on hold. Do not start any new tasks on it"))
        #expect(call(s, "project_list").text.contains("ON HOLD"))
        #expect(call(s, "agent_register", ["name": "a", "project": "/tmp/P"]).text.contains("WARNING: P is on hold"))
        #expect(call(s, "task_list", ["project": "P"]).text.hasPrefix("WARNING: P is on hold"))
        let a = id(after: "", in: call(s, "agent_register", ["project": "P"]).text)
        let waiting = try #require(try s.store.load().tasks.first)
        _ = call(s, "project_get", ["project": "P", "agent_id": a])
        let claimed = call(s, "task_claim", ["task_id": waiting.id.uuidString, "agent_id": a]).text
        #expect(claimed.hasPrefix("You are on: Waiting") && claimed.contains("WARNING: P is on hold"))
        #expect(try s.store.load().tasks.first?.state == .inProgress)
        project.onHold = false
        try s.store.save(project)
        #expect(!call(s, "task_list", ["project": "P"]).text.contains("WARNING"))
    }

    @Test func unblockOneAndMove() throws {
        let s = try server()
        _ = call(s, "agent_register", ["name": "a", "project": "/tmp/P"])
        _ = call(s, "project_add", ["path": "/tmp/Q", "description": "Project Q."])
        let t = id(after: "", in: call(s, "task_add", ["project": "P", "title": "Stuck"]).text)
        _ = call(s, "task_block", ["task_id": t, "on": "other", "why": "the measurement"])
        _ = call(s, "task_block", ["task_id": t, "on": "person", "why": "the stand-down"])
        #expect(call(s, "task_unblock", ["task_id": t, "which": "measurement"]).text.hasPrefix("Cleared one. Stuck still waits on 1: the stand-down"))
        #expect(call(s, "task_unblock", ["task_id": t, "which": "nothing"]).isError)
        #expect(call(s, "task_unblock", ["task_id": t, "which": "1"]).text.hasPrefix("Cleared the last one."))
        #expect(call(s, "task_move", ["task_id": t, "project": "Q"]).text == "Stuck is on Q's backlog.")
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
        let a = id(after: "", in: call(s, "agent_register", ["project": "P"]).text)
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

    init(start: TimeInterval = 0) { t = start }

    func tick() -> Date {
        lock.lock(); defer { lock.unlock() }
        t += 1
        return Date(timeIntervalSince1970: t)
    }

    /// The time as it stands, for a test that moves the clock itself.
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return Date(timeIntervalSince1970: t)
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        t += seconds
    }
}
