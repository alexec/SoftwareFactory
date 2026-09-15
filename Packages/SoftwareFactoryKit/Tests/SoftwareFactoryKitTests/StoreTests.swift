import Foundation
import Testing
@testable import SoftwareFactoryKit

func temporaryStore() throws -> FileStore {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "SoftwareFactoryKitTests-\(UUID().uuidString)")
    return try FileStore(root: root)
}

/// ISO 8601 keeps whole seconds, so records under test are made on a whole second.
func wholeSecond() -> Date {
    Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
}

@Suite struct StoreTests {
    @Test func roundTripsEveryKindOfRecord() throws {
        let store = try temporaryStore()
        let now = wholeSecond()
        let project = Project(name: " Where ", added: now)
        #expect(UUID(uuidString: project.id) != nil)
        #expect(project.name == "Where")
        #expect(Project.name(fromPath: "/Users/alex/Where/") == "Where")
        let task = FactoryTask(projectID: project.id, title: "Fix it", rank: 3, note: "why", created: now)
        var escalation = Escalation(
            projectID: project.id, question: "Which?", options: [.init(title: "A", recommended: true), .init(title: "B")],
            raised: now)
        try escalation.decide(escalation.options[1], at: now)
        let agent = Agent(number: 1, projectID: project.id, registered: now)
        let message = AgentMessage(recipientID: agent.id, from: "agent-2", subject: "Hello", contents: "Can you help?", sent: now)
        let artifact = Artifact(projectID: project.id, title: "Brief", body: "Do this.", agentID: agent.id, addedBy: agent.label, added: now)

        try store.save(project)
        try store.save(task)
        try store.save(escalation)
        try store.save(artifact)
        try store.save(agent)
        try store.save(message)

        let snap = try store.load()
        #expect(snap.projects == [project])
        #expect(snap.tasks == [task])
        #expect(snap.escalations == [escalation])
        #expect(snap.artifacts == [artifact])
        #expect(snap.agents == [agent])
        var gone = artifact
        gone.removed = now
        try store.save(gone)
        #expect(try store.load().artifacts.isEmpty)
        #expect(try store.messages(for: agent.id) == [message])
        #expect(snap.escalations[0].chosen?.title == "B")
        #expect(try #require(store.escalation(escalation.id)) == escalation)
    }

    @Test func everyRecordCarriesAVersionAndReadsWithoutOne() throws {
        let store = try temporaryStore()
        let project = Project(name: "a", id: "/a")
        try store.save(project)
        let file = store.root.appending(path: "projects/\(FileStore.fileName(forProject: project.id)).json")
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(text.contains("\"version\" : \(Records.version)"))
        #expect(!text.contains("description"))
        #expect(!text.contains("instructions"))

        // An older writer never wrote the field; the record still reads, as version 1.
        var stripped = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        stripped["version"] = nil
        try JSONSerialization.data(withJSONObject: stripped).write(to: file)
        let back = try #require(try store.load().projects.first)
        #expect(back.version == 1)
        #expect(back.id == "/a")

        #expect(FactoryTask(projectID: "/a", title: "t", rank: 0).version == Records.version)
        #expect(Escalation(projectID: "/a", question: "q", options: []).version == Records.version)
        #expect(Artifact(projectID: "/a", title: "Brief").version == Records.version)
        #expect(Agent(number: 1, projectID: nil).version == Records.version)
        #expect(AgentMessage(recipientID: UUID(), from: "a", subject: "s", contents: "c").version == Records.version)
        #expect(Resource(name: "r").version == Records.version)
        #expect(Lease(resourceID: UUID(), agentID: UUID(), why: "", since: .now, until: .now).version == Records.version)
    }

    @Test func aProjectWrittenWithDescriptionStillReads() throws {
        let json = """
        {"version":3,"id":"/p","name":"Old","description":"when to use it","instructions":"read this",
         "added":"2026-09-12T10:00:00Z"}
        """
        let p = try FileStore.decoder.decode(Project.self, from: Data(json.utf8))
        #expect(p.name == "Old")
        #expect(p.id == "/p")
    }

    @Test func sameIDLandsInOneFile() throws {
        let store = try temporaryStore()
        try store.save(Project(name: "first", id: "/a/b"))
        try store.save(Project(name: "second", id: "/a/b"))
        let snap = try store.load()
        #expect(snap.projects.count == 1)
        #expect(snap.projects[0].name == "second")
    }

    @Test func skipsAFileItCannotRead() throws {
        let store = try temporaryStore()
        try store.save(Project(name: "b", id: "/a/b"))
        try Data("not json".utf8).write(to: store.root.appending(path: "projects/junk.json"))
        #expect(try store.load().projects.count == 1)
    }

    @Test func deleteRemovesTheRecord() throws {
        let store = try temporaryStore()
        let task = FactoryTask(projectID: "/p", title: "t", rank: 0)
        try store.save(task)
        try store.delete(task)
        #expect(try store.load().tasks.isEmpty)
    }

    @Test func storeRootHonoursTheEnvironment() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let root = FileStore.defaultRoot(home: home)
        if ProcessInfo.processInfo.environment["SOFTWARE_FACTORY_STORE"] == nil {
            #expect(root.path == "/Users/someone/Library/Group Containers/\(FileStore.appGroup)/Store")
        }
    }
}

@Suite struct EscalationTests {
    @Test func decidingRecordsTheChoiceWhoAndWhen() throws {
        var e = Escalation(projectID: "/p", question: "q", options: [.init(title: "A", recommended: true), .init(title: "B")])
        #expect(e.isOpen)
        #expect(e.recommended?.title == "A")
        let when = Date(timeIntervalSince1970: 1000)
        try e.decide(e.options[0], by: "alex", at: when)
        #expect(!e.isOpen)
        #expect(e.decision?.at == when)
        #expect(e.decision?.by == "alex")
        #expect(e.chosen?.title == "A")
    }

    @Test func decidingAgainReplacesTheChoice() throws {
        var e = Escalation(projectID: "/p", question: "q", options: [.init(title: "A"), .init(title: "B")])
        try e.decide(e.options[0])
        try e.decide(e.options[1])
        #expect(e.chosen?.title == "B")
    }

    @Test func aNoteRidesWithTheChoiceAndOwnWordsNeedNoOption() throws {
        var e = Escalation(projectID: "/p", question: "q", options: [.init(title: "A"), .init(title: "B")])
        try e.decide(e.options[0], note: "  but only after lunch ", by: "alex")
        #expect(e.chosen?.title == "A")
        #expect(e.decision?.note == "but only after lunch")
        #expect(e.answer == "A. but only after lunch")
        #expect(!e.answeredInOwnWords)

        try e.answer("Neither: ship it without the field", by: "alex, phone")
        #expect(!e.isOpen)
        #expect(e.chosen == nil)
        #expect(e.answeredInOwnWords)
        #expect(e.answer == "Neither: ship it without the field")
        #expect(throws: EscalationError.emptyAnswer) { try e.answer("   ") }

        // A decision written before notes existed still reads.
        let old = Data(#"{"optionID":"\#(e.options[1].id.uuidString)","by":"alex","at":"2026-09-12T20:00:00Z"}"#.utf8)
        let decoded = try FileStore.decoder.decode(Escalation.Decision.self, from: old)
        #expect(decoded.optionID == e.options[1].id && decoded.note.isEmpty)
    }

    @Test func anOptionFromElsewhereIsRefused() {
        var e = Escalation(projectID: "/p", question: "q", options: [.init(title: "A"), .init(title: "B")])
        #expect(throws: EscalationError.unknownOption) {
            try e.decide(.init(title: "C"))
        }
    }

    @Test func aLinkIsOptionalAndMustBeHttpOrHttps() throws {
        #expect(try Escalation.validatedLink(nil) == "")
        #expect(try Escalation.validatedLink("  ") == "")
        #expect(try Escalation.validatedLink("https://example.com/brief.md") == "https://example.com/brief.md")
        #expect(try Escalation.validatedLink("http://127.0.0.1:4747/doc") == "http://127.0.0.1:4747/doc")
        #expect(throws: EscalationError.badLink) { try Escalation.validatedLink("javascript:alert(1)") }
        #expect(throws: EscalationError.badLink) { try Escalation.validatedLink("not a url") }
        #expect(throws: EscalationError.badLink) { try Escalation.validatedLink("file:///tmp/secret") }

        let withLink = Escalation(projectID: "/p", question: "q", link: "https://example.com/brief.md",
                                  options: [.init(title: "A"), .init(title: "B")])
        let again = try FileStore.decoder.decode(Escalation.self, from: FileStore.encoder.encode(withLink))
        #expect(again.link == "https://example.com/brief.md")

        // An older record without the key still reads.
        let old = Data(#"""
        {"id":"\#(withLink.id.uuidString)","projectID":"/p","question":"q","context":"",
         "options":[{"id":"\#(withLink.options[0].id.uuidString)","title":"A","detail":"","recommended":false},
                    {"id":"\#(withLink.options[1].id.uuidString)","title":"B","detail":"","recommended":false}],
         "raisedBy":"agent","raised":"2026-09-13T12:00:00Z"}
        """#.utf8)
        #expect(try FileStore.decoder.decode(Escalation.self, from: old).link.isEmpty)
        #expect(try FileStore.decoder.decode(Escalation.self, from: old).artifactID == nil)
    }
}

@Suite struct AgentTests {
    /// A process that has gone gives back whatever its agent was holding. This used to
    /// be an hour of silence, which was a guess: an agent thinking is silent too.
    @Test func aStoppedAgentGivesBackWhatItHeld() throws {
        let now = Date()
        let me = ProcessInfo.processInfo.processIdentifier
        var alive = Agent(number: 1, projectID: nil, registered: now.addingTimeInterval(-3600))
        alive.lastSeen = now.addingTimeInterval(-3600)   // silent for an hour, and fine
        alive.pid = me
        alive.pidStartedAt = try #require(ProcessCheck.startTime(of: me))

        var stopped = Agent(number: 2, projectID: nil, registered: now.addingTimeInterval(-60))
        stopped.lastSeen = now                           // spoke a moment ago, and gone
        stopped.pid = 0x7FFF_FFFE
        stopped.pidStartedAt = now

        let phone = Resource(name: "iPhone")
        let held = Lease(resourceID: phone.id, agentID: stopped.id, why: "", since: now.addingTimeInterval(-1000), until: now.addingTimeInterval(1000))
        let mine = Lease(resourceID: phone.id, agentID: alive.id, why: "", since: now.addingTimeInterval(-1000), until: now.addingTimeInterval(1000))
        let snap = Snapshot(agents: [alive, stopped], resources: [phone], leases: [held, mine])

        let changes = Sweep.stoppedAgents(in: snap, now: now)
        // Only the stopped one's lease comes back. Silence is not an exit.
        #expect(changes.leases.map(\.id) == [held.id])
        #expect(changes.leases[0].released == now)
        #expect(!alive.hasExited && stopped.hasExited)
    }

    @Test func quietAfterTwoMinutes() {
        let now = Date()
        var a = Agent(number: 1, projectID: nil, registered: now.addingTimeInterval(-1000))
        a.lastSeen = now.addingTimeInterval(-30)
        #expect(a.isWorking(now: now))
        a.lastSeen = now.addingTimeInterval(-11 * 60)
        #expect(!a.isWorking(now: now))
        a.lastSeen = now
        a.deregistered = now
        #expect(!a.isRegistered)
        #expect(!a.isWorking(now: now))
    }

    /// The number of agents is slots the person hands out, like any other resource: it
    /// lives in the throttle, it is clamped to what the Mac can stand, and a throttle
    /// written before it existed still reads. (T209.)
    @Test func theCapIsTheNumberOfSlotsThePersonSet() throws {
        #expect(Agents.cap() == Agents.defaultCap)
        #expect(Agents.cap(Throttle(agentSlots: 3)) == 3)
        #expect(Agents.cap(Throttle(agentSlots: 0)) == 1)
        #expect(Agents.cap(Throttle(agentSlots: 99)) == 16)
        #expect(Agents.fullMessage(cap: 1) == "The cap is 1 agent on the floor.")
        #expect(Agents.fullMessage(cap: 4) == "The cap is 4 agents on the floor.")

        let now = Date()
        let three = (1...3).map { Agent(number: $0, projectID: nil, registered: now) }
        #expect(Agents.atCap(three, cap: 3))
        #expect(!Agents.atCap(three, cap: 4))

        let older = Data(#"{"compileSlots":9,"simulatorSlots":2,"swapCeiling":0.8,"memoryFloor":0.2}"#.utf8)
        let read = try JSONDecoder().decode(Throttle.self, from: older)
        #expect(read.compileSlots == 9)
        #expect(read.agentSlots == Agents.defaultCap)
    }

    @Test func eightOnTheFloorIsTheCap() {
        let now = Date()
        let eight = (1...8).map { Agent(number: $0, projectID: nil, registered: now) }
        #expect(Agents.onTheFloor(eight).count == 8)
        #expect(Agents.atCap(eight, cap: Agents.defaultCap))
        var extra = eight
        extra.append(Agent(number: 9, projectID: nil, registered: now))
        #expect(Agents.atCap(extra, cap: Agents.defaultCap))

        var oneGone = eight
        oneGone[0].deregistered = now
        #expect(!Agents.atCap(oneGone))
        #expect(Agents.onTheFloor(oneGone).count == 7)
    }

    @Test func aStoppedAgentDoesNotCountTowardTheCap() {
        let now = Date()
        var eight = (1...8).map { Agent(number: $0, projectID: nil, registered: now) }
        eight[0].pid = 0x7FFF_FFFE
        eight[0].pidStartedAt = now
        #expect(eight[0].hasExited)
        #expect(Agents.onTheFloor(eight).count == 7)
        #expect(!Agents.atCap(eight))
    }

    @Test func anOlderAboutIsThrownAwayAndTitleAndBelRead() throws {
        let agent = Agent(number: 1, projectID: nil)
        var json = try #require(try JSONSerialization.jsonObject(with: FileStore.encoder.encode(agent)) as? [String: Any])
        #expect(json["about"] == nil)
        json["about"] = "Builds the app."
        json.removeValue(forKey: "title")
        json.removeValue(forKey: "bel")
        let decoded = try FileStore.decoder.decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.title.isEmpty)
        #expect(!decoded.bel)

        var ringing = agent
        ringing.title = "Reviewing the brief"
        ringing.bel = true
        let again = try FileStore.decoder.decode(Agent.self, from: FileStore.encoder.encode(ringing))
        #expect(again.title == "Reviewing the brief")
        #expect(again.bel)
        #expect(Agent.preparedTitle("  hi  ") == "hi")
        #expect(Agent.preparedTitle(String(repeating: "x", count: Agent.maxTitle + 8)).count == Agent.maxTitle)
    }

    @Test func anAgentWrittenBeforeWantsLaunchStillReads() throws {
        let agent = Agent(number: 1, projectID: nil)
        var json = try #require(try JSONSerialization.jsonObject(with: FileStore.encoder.encode(agent)) as? [String: Any])
        json.removeValue(forKey: "wantsLaunch")
        let decoded = try FileStore.decoder.decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.wantsLaunch)
        #expect(!decoded.wantsNudge)
        json.removeValue(forKey: "wantsNudge")
        let older = try FileStore.decoder.decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!older.wantsNudge)
    }

    @Test func olderAgentsStartTheirQuietTimerFromLastSeen() throws {
        let now = Date()
        let agent = Agent(number: 1, projectID: nil, registered: now.addingTimeInterval(-3600))
        var json = try #require(try JSONSerialization.jsonObject(with: FileStore.encoder.encode(agent)) as? [String: Any])
        json.removeValue(forKey: "isConnected")
        let decoded = try FileStore.decoder.decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.isConnected)
    }
}

@Suite struct EscalationsViewTests {
    @Test func openInFullThenTheThreeNewestDecidedFromTheLastHour() throws {
        let t0 = Date(timeIntervalSince1970: 1000)
        func q(_ n: Int, decidedAt: TimeInterval? = nil) throws -> Escalation {
            var e = Escalation(projectID: "/p", question: "q\(n)", options: [.init(title: "A"), .init(title: "B")], raised: t0.addingTimeInterval(TimeInterval(n)))
            if let decidedAt { try e.decide(e.options[0], at: t0.addingTimeInterval(decidedAt)) }
            return e
        }
        let all = [try q(5), try q(1), try q(2, decidedAt: 50), try q(3, decidedAt: 70), try q(4, decidedAt: 60), try q(6, decidedAt: 10),
                   Escalation(projectID: "/other", question: "x", options: [.init(title: "A")])]
        let shown = Escalations.visible(for: "/p", in: all, now: t0.addingTimeInterval(100))
        #expect(shown.open.map(\.question) == ["q1", "q5"])
        #expect(shown.decided.map(\.question) == ["q3", "q4", "q2"])
    }

    @Test func aDecidedQuestionAgesOutAfterAnHour() throws {
        let decidedAt = Date(timeIntervalSince1970: 1000)
        var recent = Escalation(projectID: "/p", question: "recent", options: [.init(title: "A")], raised: decidedAt)
        var expired = Escalation(projectID: "/p", question: "expired", options: [.init(title: "A")], raised: decidedAt)
        try recent.decide(recent.options[0], at: decidedAt)
        try expired.decide(expired.options[0], at: decidedAt)

        let shortlyBeforeExpiry = Escalations.visible(
            for: "/p",
            in: [recent, expired],
            now: decidedAt.addingTimeInterval(Escalations.decidedVisibleFor - 1)
        )
        #expect(shortlyBeforeExpiry.decided.map(\.question) == ["recent", "expired"])

        let atExpiry = Escalations.visible(
            for: "/p",
            in: [recent, expired],
            now: decidedAt.addingTimeInterval(Escalations.decidedVisibleFor)
        )
        #expect(atExpiry.decided.isEmpty)
    }
}
