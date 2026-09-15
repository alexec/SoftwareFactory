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

    @Test func aProjectIsANameWithNoDescriptionOrInstructions() throws {
        let s = try server()
        #expect(call(s, "task_add", ["project": "Missing", "title": "No project"]).isError)
        #expect(!call(s, "project_add", ["name": "Guided"]).isError)
        #expect(!call(s, "project_list").text.contains("description"))
        let agentID = try startAgent(s, project: "Guided").label
        #expect(!call(s, "task_add", ["project": "Guided", "title": "Do it", "agent_id": agentID]).isError)
        let project = call(s, "project_get", ["project": "Guided", "agent_id": agentID]).text
        #expect(project.contains("name: Guided"))
        #expect(!project.contains("description:"))
        #expect(!project.contains("instructions:"))
        #expect(call(s, "project_set", [
            "project": "Guided", "set_description": "no longer a field",
        ]).text.contains("folder or on_hold"))
        #expect(!call(s, "task_note", ["task_id": "T1", "text": "a line", "agent_id": agentID]).isError)
    }

    /// Naming a project nobody has used makes it. An agent whose work belongs to no
    /// project registers without one. (Alex, 12 Sep 2026: it is allowed.)
    @Test func registeringNamesTheProjectOrNone() throws {
        let s = try server()
        let a = try startAgent(s, project: "Brand New").label
        let agent = try #require(try s.store.load().agents.first { $0.label == a })
        let project = try #require(try s.store.load().projects.first { $0.id == agent.projectID })
        #expect(project.name == "Brand New")

        let loose = try startAgent(s).label
        #expect(try s.store.load().agents.first { $0.label == loose }?.projectID == nil)
        // Registering again without one keeps the project it already had.
        #expect(try s.store.load().agents.first { $0.label == a }?.projectID == project.id)
    }

    /// An agent is its A<n> and nothing else: registration takes no name, a name sent
    /// anyway is ignored, and nothing the factory says back carries one.
    /// (A9, 13 Sep 2026: T137.)
    // A test stood here for registering with a pid. The factory reads the pid off the
    // pane it launched the agent into, so there is no registration to carry it and
    // nothing for an agent to get wrong. ProcessCheckTests covers what the pid means.
    // (T-session, 13 Sep 2026.)

    @Test func anAgentIsOnlyItsNumber() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "Named", "description": "Work for named agents."])
        let a = try startAgent(s, project: "Named").label
        // There is no second name to disagree with the label: the record has only its
        // number, and the label is made from it. (T158, 13 Sep 2026.)
        let stored = try #require(try s.store.load().agents.first { $0.label == a })
        #expect(stored.number.map { "A\($0)" } == a)

        // A second agent, so the first has someone to read about.
        let b = try startAgent(s, project: "Named").label
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
        let a = try startAgent(s, project: "Together").label
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
        let a = try startAgent(s, project: "Q").label
        _ = call(s, "project_read", ["project": "Q", "agent_id": a])
        _ = call(s, "task_add", ["project": "Q", "title": "Something to read", "agent_id": a])
        _ = call(s, "escalation_raise", ["agent_id": a, "project": "Q", "question": "Which?",
                                        "options": [["title": "A"], ["title": "B"]]])
        _ = call(s, "resource_add", ["name": "iPhone", "agent_id": a])

        for tool in MCPServer.Tool.all where tool.kind == .query {
            let before = try fingerprint(of: s.store)
            var args: [String: Any] = ["agent_id": a, "timeout_seconds": 0]
            if tool.name == "task_next" || tool.name == "task_list" || tool.name == "project_read" || tool.name == "artifact_list" { args["project"] = "Q" }
            if tool.name == "escalation_await" { args["escalation_id"] = UUID().uuidString }
            if tool.name == "artifact_read" { args["artifact_id"] = UUID().uuidString }
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
        let a = try startAgent(s, project: "W").label

        #expect(call(s, "task_next", ["project": "W", "timeout_seconds": 0]).text == "Nothing waiting. Call task_next again.")
        let raised = call(s, "escalation_raise", ["agent_id": a, "project": "W", "question": "Which?",
                                                 "options": [["title": "A"], ["title": "B"]]])
        let escalation = id(after: "", in: raised.text)
        #expect(call(s, "escalation_await", ["escalation_id": escalation, "timeout_seconds": 0]).text
            == "Still open. Call escalation_await again.")
        // None of them is an error: the agent is meant to come back.
        #expect(!call(s, "task_next", ["project": "W", "timeout_seconds": 0]).isError)
        // And every one of them takes the same argument.
        for tool in ["task_next", "escalation_await"] {
            let defined = try #require(MCPServer.Tool.all.first { $0.name == tool })
            #expect(defined.properties["timeout_seconds"] != nil)
        }
    }

    @Test func agentCreateWritesOneDownAndAsksTheAppToStartIt() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "Spawn", "folder": "/tmp/Spawn"])
        let a = try startAgent(s, project: "Spawn").label
        let created = call(s, "agent_create", ["agent_id": a])
        #expect(!created.isError)
        #expect(created.text.hasPrefix("Starting A"))
        #expect(created.text.contains("on Spawn"))
        #expect(created.text.contains("session_id"))
        let agents = try s.store.load().agents
        let newborn = try #require(agents.first { $0.wantsLaunch })
        let spawnID = try s.store.load().projects.first { $0.name == "Spawn" }?.id
        #expect(newborn.projectID == spawnID)
        #expect(newborn.label != a)
    }

    @Test func agentCreateDefaultsToTheCallerProjectAndCanNameATask() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "Spawn", "folder": "/tmp/Spawn"])
        let a = try startAgent(s, project: "Spawn").label
        _ = call(s, "task_add", ["project": "Spawn", "title": "The one job", "agent_id": a])
        let created = call(s, "agent_create", ["agent_id": a, "task_id": "T1"])
        #expect(!created.isError)
        #expect(created.text.contains("The one job"))
        let snap = try s.store.load()
        let newborn = try #require(snap.agents.first { $0.wantsLaunch })
        #expect(newborn.taskID == snap.tasks.first { $0.number == 1 }?.id)
        #expect(snap.tasks.first { $0.number == 1 }?.agentID == newborn.id)
    }

    @Test func agentCreateRefusesANinthOnTheFloor() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "Packed", "folder": "/tmp/Packed"])
        var last = ""
        for _ in 1...Agents.defaultCap {
            last = try startAgent(s, project: "Packed").label
        }
        let ninth = call(s, "agent_create", ["agent_id": last])
        #expect(ninth.isError)
        #expect(ninth.text.contains(Agents.fullMessage(cap: Agents.defaultCap)))
        #expect(try s.store.load().agents.filter(\.isRegistered).count == Agents.defaultCap)
    }

    /// The cap is the person's to set, and `agent_create` reads theirs, not the default.
    /// (T209.)
    @Test func agentCreateObeysTheCapThePersonSet() throws {
        let s = try server()
        try s.store.save(Throttle(agentSlots: 2))
        _ = call(s, "project_add", ["name": "Small", "folder": "/tmp/Small"])
        var last = ""
        for _ in 1...2 {
            last = try startAgent(s, project: "Small").label
        }
        let third = call(s, "agent_create", ["agent_id": last])
        #expect(third.isError)
        #expect(third.text.contains("The cap is 2 agents on the floor."))
        #expect(try s.store.load().agents.filter(\.isRegistered).count == 2)
    }

    @Test func agentCreateNeedsAProjectWithAFolder() throws {
        let s = try server()
        let none = try startAgent(s).label
        #expect(call(s, "agent_create", ["agent_id": none]).text.contains("Name a project"))
        _ = call(s, "project_add", ["name": "NoFolder"])
        let onIt = try startAgent(s, project: "NoFolder").label
        #expect(call(s, "agent_create", ["agent_id": onIt]).text.contains("folder"))
    }

    @Test func agentNudgeWritesTheNudgeDownForTheAppToType() throws {
        let s = try server()
        let lead = try startAgent(s, project: "Mail").label
        let worker = try startAgent(s, project: "Mail").label
        let poked = call(s, "agent_nudge", ["agent_id": lead, "to_agent_id": worker])
        #expect(!poked.isError)
        #expect(poked.text == "Nudged \(worker).")
        let workerID = try #require(try s.store.load().agents.first { $0.label == worker }?.id)
        let waiting = try #require(try s.store.messages(for: workerID).last)
        #expect(waiting.subject == "Nudge")
        #expect(waiting.from == lead)
        #expect(waiting.contents == LaunchPrompt.nudge)
        // Undelivered is what the app looks for, and a nudge is typed in bare: it is the
        // line agents already read.
        #expect(waiting.delivered == nil)
        #expect(waiting.isNudge)
        #expect(waiting.terminalLine == LaunchPrompt.nudge)
        #expect(call(s, "agent_nudge", ["agent_id": lead, "to_agent_id": lead]).isError)
        #expect(call(s, "agent_nudge", ["agent_id": lead, "to_agent_id": "A99"]).isError)
    }

    @Test func thereIsNoToolForReadingMessages() throws {
        // Messages are typed into the agent's terminal, so there is nothing to collect.
        #expect(!MCPServer.Tool.all.contains { $0.name == "inbox" })
        let s = try server()
        let a = try startAgent(s, project: "Mail").label
        #expect(call(s, "inbox", ["agent_id": a]).isError)
        #expect(call(s, "agent_messages", ["agent_id": a]).isError)
    }

    @Test func agentsCanSendEachOtherAMessageTheAppTypesIn() throws {
        let s = try server()
        let lead = try startAgent(s, project: "Mail").label
        let worker = try startAgent(s, project: "Mail").label

        let listed = call(s, "agent_list", ["agent_id": lead]).text
        #expect(listed.contains(worker))
        #expect(!listed.contains(lead))

        let sent = call(s, "agent_message_send", [
            "agent_id": lead, "to_agent_id": worker, "subject": "Please review", "contents": "Start with the MCP server.",
        ])
        #expect(sent.text.hasPrefix("Sent to \(worker)."))
        let workerID = try #require(try s.store.load().agents.first { $0.label == worker }?.id)
        let waiting = try #require(try s.store.messages(for: workerID).last)
        #expect(waiting.from == lead && waiting.subject == "Please review")
        #expect(waiting.delivered == nil)
        // Not a nudge, so the typed line says who it is from: the agent cannot tell a
        // typed line from the person at the keyboard.
        #expect(!waiting.isNudge)
        #expect(waiting.terminalLine == "Message from \(lead), Please review: Start with the MCP server.")
        #expect(call(s, "agent_message_send", [
            "agent_id": lead, "to_agent_id": lead, "subject": "No", "contents": "No",
        ]).isError)
    }

    @Test func aMessageIsTypedAsOneLineWhateverItCarries() throws {
        let plain = AgentMessage(recipientID: UUID(), from: "A2", subject: "", contents: "Look at T12.")
        #expect(plain.terminalLine == "Message from A2: Look at T12.")
        let nudge = AgentMessage(recipientID: UUID(), from: "A2", subject: "Nudge", contents: LaunchPrompt.nudge)
        #expect(nudge.terminalLine == LaunchPrompt.nudge)
    }

    @Test func aNearMissProjectNameIsRefusedRatherThanMadeTwice() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "Sleeper Train", "description": "Train work."])
        _ = call(s, "project_add", ["name": "Out of Mind", "description": "Other work."])
        #expect(Projects.nearMiss("NightSleeper", in: try s.store.load().projects)?.name == "Sleeper Train")
        #expect(Projects.nearMiss("sleeper-train", in: try s.store.load().projects) == nil)   // that one is exact
        #expect(Projects.exact("sleeper-train", in: try s.store.load().projects)?.name == "Sleeper Train")
        #expect(Projects.nearMiss("Walkist", in: try s.store.load().projects) == nil)
        let refused = call(s, "project_add", ["name": "NightSleeper", "description": "Sleeper work."])
        #expect(refused.isError && refused.text.contains("there is Sleeper Train"))
        #expect(call(s, "task_add", ["project": "Sleeper", "title": "x"]).isError)
        #expect(call(s, "project_add", ["name": "Sleepers", "description": "Sleep work."]).isError)
        #expect(!call(s, "project_add", ["name": "Sleepers", "description": "Sleep work.", "force": true]).isError)
        #expect(!call(s, "project_add", ["name": "Walkist", "description": "Walking."]).isError)
        #expect(try s.store.load().projects.count == 4)
    }

    func call(_ s: MCPServer, _ tool: String, _ args: [String: Any] = [:], id: Int = 1) -> (text: String, isError: Bool) {
        // Every tool takes the caller's session now. A test that does not name one gets
        // a throwaway: the point of most of them is the tool, not who called it. A test
        // that says which agent is calling says it the way a person would, by label, and
        // this looks up the session for it. The tools themselves take only the UUID.
        var args = args
        if let label = args.removeValue(forKey: "agent_id") as? String {
            args["session_id"] = (try? s.store.load())?.agents.first { $0.label == label }?.id.uuidString ?? label
        }
        if args["session_id"] == nil { args["session_id"] = UUID().uuidString }
        let response = s.handle(["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                 "params": ["name": tool, "arguments": args]], agentID: nil)!
        let result = response["result"] as! [String: Any]
        let content = result["content"] as! [[String: Any]]
        return (content[0]["text"] as! String, result["isError"] as! Bool)
    }

    /// Registration without a connection behind it, as a fresh MCP session makes it: the
    /// agent's own agent_id is all there is to go on.
    /// An agent on the floor, the way the factory makes one: written down with a number
    /// and a project before anything launches. There is no registering any more, so a
    /// test that needs an agent writes one the same way the app does. Returns its
    /// session, which is what every tool takes. (T-session, 13 Sep 2026.)
    @discardableResult
    func startAgent(_ s: MCPServer, project: String? = nil) throws -> (session: String, label: String) {
        var project = project
        if let ref = project {
            // An agent registering used to make its project as a side effect. It is made
            // outright now, by name or by folder, the way the person would.
            if ref.hasPrefix("/") {
                _ = call(s, "project_add", ["path": ref, "description": "Work in \(ref)."])
            } else {
                _ = call(s, "project_add", ["name": ref, "description": "Work for \(ref)."])
            }
            let wanted = ref.hasPrefix("/") ? Project.name(fromPath: ref) : ref
            project = try s.store.load().projects.first { $0.name == wanted }?.id
        }
        // On the server's clock, not the wall's: a test with a fake clock would otherwise
        // write an agent from the future.
        let agent = Agents.reserve(number: try s.store.takeAgentNumber(), projectID: project, now: s.now())
        try s.store.save(agent)
        return (agent.id.uuidString, agent.label)
    }

    func register(_ s: MCPServer, _ args: [String: Any] = [:], bound: String? = nil) -> (text: String, isError: Bool) {
        let response = s.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                 "params": ["name": "agent_register", "arguments": args]], agentID: bound)!
        let result = response["result"] as! [String: Any]
        let content = result["content"] as! [[String: Any]]
        return (content[0]["text"] as! String, result["isError"] as! Bool)
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
        #expect(names.contains("artifact_add"))
        #expect(names.contains("artifact_list"))
        #expect(names.contains("artifact_read"))
        #expect(names.contains("agent_create"))
        #expect(names.contains("agent_nudge"))
        // Registering and deregistering are gone: the factory makes the agent and the
        // kernel says when it stops. (T-session, 13 Sep 2026.)
        #expect(!names.contains("agent_register"))
        #expect(!names.contains("agent_deregister"))
        #expect(names.allSatisfy { $0.allSatisfy { $0.isLetter || $0 == "_" } })
        // The connection says who is calling, so no tool asks for agent_id. Registration
        // is the one exception: an agent the app started is told the name to ask for.
        #expect(tools.allSatisfy {
            let schema = $0["inputSchema"] as! [String: Any]
            let properties = schema["properties"] as! [String: Any]
            return properties["agent_id"] == nil
        })

        // Every tool takes a call description, so the transcript can show what
        // it is doing rather than the bare tool name.
        for tool in tools {
            let schema = tool["inputSchema"] as! [String: Any]
            let properties = schema["properties"] as! [String: Any]
            let name = tool["name"] as! String
            #expect(properties["description"] != nil, "\(name) has no description")
            let required = schema["required"] as! [String]
            #expect(!required.contains("description"), "\(name) must not require a project description")
        }

        let unknown = s.handle(["jsonrpc": "2.0", "id": 3, "method": "nope"])!
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func artifactsAreFiledIdempotentlyAndReadInFull() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "Packed", "description": "Packing work."])
        let a = try startAgent(s, project: "Packed").label
        let added = call(s, "artifact_add", [
            "agent_id": a, "project": "Packed", "title": "Login", "body": "One field.",
        ])
        #expect(!added.isError)
        let id1 = id(after: "artifact_id:", in: added.text)
        let again = call(s, "artifact_add", [
            "agent_id": a, "project": "Packed", "title": "Login", "body": "Two fields.",
        ])
        #expect(again.text.hasPrefix("Already there"))
        #expect(id(after: "artifact_id:", in: again.text) == id1)
        #expect(try s.store.load().artifacts.count == 1)

        let listed = call(s, "artifact_list", ["agent_id": a, "project": "Packed"])
        #expect(listed.text.contains("Login"))
        #expect(!listed.text.contains("One field."))
        let read = call(s, "artifact_read", ["agent_id": a, "artifact_id": id1])
        #expect(read.text.contains("One field."))
        #expect(!call(s, "artifact_set", ["agent_id": a, "artifact_id": id1, "body": "Two fields."]).isError)
        #expect(call(s, "artifact_read", ["agent_id": a, "artifact_id": id1]).text.contains("Two fields."))

        let raised = call(s, "escalation_raise", [
            "agent_id": a, "project": "Packed", "question": "This shape?",
            "artifact_id": id1,
            "options": [["title": "Yes"], ["title": "No"]],
        ])
        #expect(!raised.isError)
        #expect(try s.store.load().escalations.first?.artifactID?.uuidString == id1)

        #expect(!call(s, "artifact_remove", ["agent_id": a, "artifact_id": id1, "reason": "done"]).isError)
        #expect(call(s, "artifact_list", ["agent_id": a, "project": "Packed"]).text.hasPrefix("No artifacts"))
        #expect(call(s, "artifact_read", ["agent_id": a, "artifact_id": id1]).isError)

        for n in 1...Artifacts.cap {
            #expect(!call(s, "artifact_add", [
                "agent_id": a, "project": "Packed", "title": "Doc \(n)",
            ]).isError)
        }
        let twentyFirst = call(s, "artifact_add", [
            "agent_id": a, "project": "Packed", "title": "One more",
        ])
        #expect(twentyFirst.isError)
        #expect(twentyFirst.text.contains(Artifacts.fullMessage))
        // A question with a new link still raises when the project is at the cap.
        let atCap = call(s, "escalation_raise", [
            "agent_id": a, "project": "Packed", "question": "Go anyway?",
            "link": "https://example.com/overflow.md",
            "options": [["title": "Yes"], ["title": "No"]],
        ])
        #expect(!atCap.isError)
        let overflow = try #require(try s.store.load().escalations.first { $0.question == "Go anyway?" })
        #expect(overflow.link == "https://example.com/overflow.md")
        #expect(overflow.artifactID == nil)
        #expect(try s.store.load().artifacts.count == Artifacts.cap)
    }

    @Test func theNarrowSlice() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "Packed", "description": "Packing work."])
        let reg = (text: try startAgent(s, project: "/tmp/Packed").label, isError: false)
        #expect(!reg.isError)
        let agentID = id(after: "agent_id:", in: reg.text)
        #expect(agentID == "A1")

        let raised = call(s, "escalation_raise", [
            "agent_id": agentID, "project": "Packed", "question": "Which weather source?",
            "context": "Two choices.",
            "link": "https://example.com/weather.md",
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
        #expect(e.link == "https://example.com/weather.md")
        #expect(e.artifactID != nil)
        #expect(e.isOpen)
        let filed = try #require(try s.store.load().artifacts.first)
        #expect(filed.link == "https://example.com/weather.md")
        #expect(filed.id == e.artifactID)
        #expect(call(s, "escalation_list", ["project": "Packed"]).text.contains("link: https://example.com/weather.md"))
        #expect(call(s, "artifact_list", ["project": "Packed", "agent_id": agentID]).text.contains("example.com/weather.md"))
        let reread = call(s, "artifact_read", ["artifact_id": filed.id.uuidString, "agent_id": agentID])
        #expect(!reread.isError)
        #expect(reread.text.contains("example.com/weather.md"))
        let again = call(s, "escalation_raise", [
            "agent_id": agentID, "project": "Packed", "question": "Still?",
            "link": "https://example.com/weather.md",
            "options": [["title": "A"], ["title": "B"]],
        ])
        #expect(!again.isError)
        #expect(try s.store.load().artifacts.count == 1)
        #expect(call(s, "escalation_raise", [
            "agent_id": agentID, "project": "Packed", "question": "No?",
            "link": "javascript:alert(1)",
            "options": [["title": "A"], ["title": "B"]],
        ]).isError)

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

        // There is no goodbye to say. An agent stops when its process stops, and the
        // factory asks the kernel rather than waiting to be told. (T-session.)
        #expect(!call(s, "agent_deregister", ["agent_id": agentID]).text.isEmpty)
    }

    @Test func tasksRoundTrip() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "Where", "description": "Where work."])
        let agentID = try startAgent(s, project: "/tmp/Where").label
        let t1 = id(after: "", in: call(s, "task_add", ["project": "Where", "title": "First", "note": "the rooms run together\nsplit on pauses"]).text)
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

        _ = call(s, "project_get", ["project": "Where", "agent_id": agentID])
        #expect(call(s, "task_claim", ["task_id": t1, "agent_id": agentID]).text.hasPrefix("You are on: First\nnote: the rooms run together\nsplit on pauses"))
        let list = call(s, "task_list", ["project": "Where"]).text
        #expect(list.split(separator: "\n").first.map { $0.contains("inProgress") && $0.contains("First") } == true)
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
        let agentID = try startAgent(s, project: "P").label
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
        let a = try startAgent(s, project: "Shared").label
        let b = try startAgent(s, project: "Shared").label
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

        // A stopped agent gives its lease back without saying anything: its process is
        // gone, so Sweep.stoppedAgents releases what it held. (T-session, 13 Sep 2026.)
        var holder = try #require(try s.store.load().agents.first { $0.label == b })
        holder.pid = 0x7FFF_FFFE
        holder.pidStartedAt = .now
        try s.store.save(holder)
        for lease in Sweep.stoppedAgents(in: try s.store.load(), now: .now).leases { try s.store.save(lease) }
        #expect(call(s, "resource_list").text.contains("1 of 1 free"))
        #expect(call(s, "resource_lease", ["agent_id": a, "resource": "Nothing"]).isError)
    }

    @Test func aQuestionFromATaskBlocksItUntilAnswered() throws {
        let s = try server()
        let a = try startAgent(s, project: "/tmp/P").label
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
        #expect(call(s, "task_list", ["project": "P"]).text.hasPrefix("WARNING: P is on hold"))
        let a = try startAgent(s, project: "P").label
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
        // Both projects made outright: an agent registering used to make one as a side
        // effect, and there is no registering now.
        _ = call(s, "project_add", ["name": "P", "description": "Project P."])
        _ = call(s, "project_add", ["path": "/tmp/Q", "description": "Project Q."])
        let t = id(after: "", in: call(s, "task_add", ["project": "P", "title": "Stuck"]).text)
        _ = call(s, "task_block", ["task_id": t, "on": "other", "why": "the measurement"])
        _ = call(s, "task_block", ["task_id": t, "on": "person", "why": "the stand-down"])
        #expect(call(s, "task_unblock", ["task_id": t, "which": "measurement"]).text.hasPrefix("Cleared one. Stuck still waits on 1: the stand-down"))
        #expect(call(s, "task_unblock", ["task_id": t, "which": "nothing"]).isError)
        #expect(call(s, "task_unblock", ["task_id": t, "which": "1"]).text.hasPrefix("Cleared the last one."))
        let refused = call(s, "task_move", ["task_id": t, "project": "Q"])
        #expect(refused.isError && refused.text.contains("stays on the project"))
        #expect(call(s, "task_list", ["project": "P"]).text.contains("Stuck"))
        #expect(call(s, "task_list", ["project": "Q"]).text == "Nothing on the backlog.")
    }

    @Test func blockingATaskSaysWhatIsNext() throws {
        let s = try server()
        _ = call(s, "project_add", ["name": "P", "description": "Project P."])
        let a = try startAgent(s, project: "/tmp/P").label
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
        let a = try startAgent(s, project: "/tmp/P").label
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
        let a = try startAgent(s, project: "P").label
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
