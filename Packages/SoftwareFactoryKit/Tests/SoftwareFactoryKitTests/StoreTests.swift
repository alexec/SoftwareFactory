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
        // The person can throw a message away: it is a receipt of what was said to the
        // agent, and the agent has already had it. (Alex, 14 Sep 2026.)
        try store.delete(message)
        #expect(try store.messages(for: agent.id).isEmpty)
        try store.delete(message)
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
    }

    @Test func anAgentStillCarryingWantsNudgeStillReads() throws {
        // The flag is gone: a nudge is a message and the message says whether it was
        // typed. A record written while the flag existed must still open. (14 Sep 2026.)
        let agent = Agent(number: 1, projectID: nil)
        var json = try #require(try JSONSerialization.jsonObject(with: FileStore.encoder.encode(agent)) as? [String: Any])
        json["wantsNudge"] = true
        let decoded = try FileStore.decoder.decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.id == agent.id)
    }

    @Test func aMessageWrittenBeforeTerminalDeliveryCountsAsDelivered() throws {
        // Those were read out of an inbox that no longer exists. Typing them in now would
        // replay old mail into a working agent's terminal.
        let message = AgentMessage(recipientID: UUID(), from: "A1", subject: "Old", contents: "Read long ago.")
        var json = try #require(try JSONSerialization.jsonObject(with: FileStore.encoder.encode(message)) as? [String: Any])
        json.removeValue(forKey: "delivered")
        let decoded = try FileStore.decoder.decode(AgentMessage.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.delivered == decoded.sent)
        // One written now is waiting to be typed.
        #expect(AgentMessage(recipientID: UUID(), from: "A1", subject: "New", contents: "x").delivered == nil)
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

@Suite struct ProjectFolderTests {
    @Test func aProjectWithNoFolderHasNothingToOpen() {
        #expect(Projects.folder(nil, home: "/Users/alex") == nil)
        #expect(Projects.folder("", home: "/Users/alex") == nil)
        #expect(Projects.folder("   ", home: "/Users/alex") == nil)
    }

    @Test func aPlainPathIsItself() {
        #expect(Projects.folder("/Work/Thing", home: "/Users/alex")?.path == "/Work/Thing")
    }

    @Test func theTildeThePersonWasShownComesOffAgain() {
        #expect(Projects.folder("~/Work/Thing", home: "/Users/alex")?.path == "/Users/alex/Work/Thing")
        #expect(Projects.folder("~", home: "/Users/alex")?.path == "/Users/alex")
        // It round trips with what they were shown.
        let path = "/Users/alex/Work/Thing"
        #expect(Projects.folder(Projects.shortPath(path, home: "/Users/alex"), home: "/Users/alex")?.path == path)
    }

    @Test func aTildeInAFolderNameIsNotAHome() {
        #expect(Projects.folder("/Work/~odd", home: "/Users/alex")?.path == "/Work/~odd")
    }

    @Test func aPathThatIsNotAbsoluteIsNoFolderAtAll() {
        // It would otherwise be read against the working directory, which is wherever
        // the app was launched from, and open a folder nobody meant.
        #expect(Projects.folder("Work/Thing", home: "/Users/alex") == nil)
        #expect(Projects.folder("~odd/Work", home: "/Users/alex") == nil)
        #expect(Projects.folder("~/Work", home: "") == nil)
    }
}

/// Putting a project on hold stops the agents on it. On hold used to mean nothing new is
/// handed out while the agents already on it worked on, which is not what a person means
/// by it. (T309.)
@Suite struct HoldStopsAgentsTests {
    private func live(_ number: Int, on projectID: String?) throws -> Agent {
        let me = ProcessInfo.processInfo.processIdentifier
        var agent = Agent(number: number, projectID: projectID, registered: Date())
        agent.pid = me
        agent.pidStartedAt = try #require(ProcessCheck.startTime(of: me))
        return agent
    }

    @Test func theAgentsOnTheProjectJustHeldAreStopped() throws {
        var project = Project(name: "Sleeper Train")
        let other = Project(name: "Hold Still")
        let mine = try live(1, on: project.id)
        let theirs = try live(2, on: other.id)
        let loose = try live(3, on: nil)
        let before = Snapshot(projects: [project, other], agents: [mine, theirs, loose])
        project.onHold = true
        let after = Snapshot(projects: [project, other], agents: [mine, theirs, loose])

        #expect(Sweep.agentsHeld(before: before, after: after).map(\.id) == [mine.id])
    }

    @Test func aProjectThatWasAlreadyOnHoldIsLeftAlone() throws {
        var project = Project(name: "Sleeper Train")
        project.onHold = true
        let mine = try live(1, on: project.id)
        let snapshot = Snapshot(projects: [project], agents: [mine])
        #expect(Sweep.agentsHeld(before: snapshot, after: snapshot).isEmpty)
    }

    /// At launch the factory has no previous snapshot, so every held project would look
    /// like one that had just been held and every agent on one would be stopped as the
    /// app opened.
    @Test func aProjectSeenForTheFirstTimeIsNoTransition() throws {
        var project = Project(name: "Sleeper Train")
        project.onHold = true
        let mine = try live(1, on: project.id)
        #expect(Sweep.agentsHeld(before: Snapshot(), after: Snapshot(projects: [project], agents: [mine])).isEmpty)
    }

    @Test func comingOffHoldStopsNobody() throws {
        var project = Project(name: "Sleeper Train")
        project.onHold = true
        let mine = try live(1, on: project.id)
        let before = Snapshot(projects: [project], agents: [mine])
        project.onHold = false
        #expect(Sweep.agentsHeld(before: before, after: Snapshot(projects: [project], agents: [mine])).isEmpty)
    }

    /// An agent that registered from somewhere else never told us a process, so there is
    /// nothing here to stop. It is left running and the hold is only a warning to it.
    @Test func anExternalAgentIsNotStopped() throws {
        var project = Project(name: "Sleeper Train")
        let outside = Agent(number: 9, projectID: project.id, registered: Date())
        let before = Snapshot(projects: [project], agents: [outside])
        project.onHold = true
        #expect(Sweep.agentsHeld(before: before, after: Snapshot(projects: [project], agents: [outside])).isEmpty)
    }
}

/// Deleting an agent's status reports takes them off the disk. The rule is tested in
/// ArtifactsWhenAnAgentGoesTests; this is the store end of it, because a delete that
/// looks in the wrong folder or at the wrong name fails silently. (T310.)
@Suite struct DeletingAnAgentsReportsTests {
    @Test func theReportsGoAndTheNotesStay() throws {
        let store = try temporaryStore()
        let agent = Agent(number: 1, projectID: "p", registered: wholeSecond())
        let report = Artifact(projectID: "p", title: "How it is going",
                              kind: .statusReport, agentID: agent.id)
        let elsewhere = Artifact(projectID: "q", title: "How it is going there",
                                 kind: .statusReport, agentID: agent.id)
        let note = Artifact(projectID: "p", title: "The plan", body: "x", agentID: agent.id)
        let theirs = Artifact(projectID: "p", title: "Somebody else's report",
                              kind: .statusReport, agentID: UUID())
        try store.save(agent)
        for a in [report, elsewhere, note, theirs] { try store.save(a) }
        #expect(try store.load().artifacts.count == 4)

        for going in Artifacts.statusReports(by: agent.id, in: try store.load().artifacts) {
            try store.delete(going)
        }
        try store.delete(agent)

        let after = try store.load()
        #expect(after.agents.isEmpty)
        #expect(Set(after.artifacts.map(\.id)) == Set([note.id, theirs.id]))
    }
}

// The poking suite went with the nudge (T470). Work landing on a project whose agents were
// all idle used to send the first of them the nudge line, which told it a person had asked
// when nobody had. What carries it now is the person: filing a task and starting an agent
// are an inch apart on the same page since T431.

/// An agent with nothing to do and nothing coming is stopped. Each test here is a way of
/// being busy that looks like silence. (T357.)
@Suite struct StoppingIdleAgentsTests {
    let hour: TimeInterval = 60 * 60

    private func idle(_ number: Int, on projectID: String?, since ago: TimeInterval) throws -> Agent {
        let me = ProcessInfo.processInfo.processIdentifier
        var a = Agent(number: number, projectID: projectID, registered: Date().addingTimeInterval(-ago))
        a.lastSeen = .now
        a.pid = me
        a.pidStartedAt = try #require(ProcessCheck.startTime(of: me))
        return a
    }

    private func task(_ title: String, on projectID: String, state: FactoryTask.State,
                      agentID: UUID? = nil, ago: TimeInterval = 0) -> FactoryTask {
        var t = FactoryTask(projectID: projectID, title: title, state: state, rank: 0)
        t.agentID = agentID
        t.updated = Date().addingTimeInterval(-ago)
        return t
    }

    @Test func anHourWithNothingToDo() throws {
        let project = Project(name: "Sleeper Train")
        let spent = try idle(1, on: project.id, since: hour + 60)
        let snapshot = Snapshot(projects: [project], agents: [spent])
        #expect(Sweep.idleAgentsToStop(in: snapshot, messages: [], now: .now).map(\.id) == [spent.id])
    }

    @Test func notBeforeTheHourIsUp() throws {
        let project = Project(name: "Sleeper Train")
        let fresh = try idle(1, on: project.id, since: 60 * 30)
        #expect(Sweep.idleAgentsToStop(in: Snapshot(projects: [project], agents: [fresh]),
                                       messages: [], now: .now).isEmpty)
    }

    /// The hour runs from the last task it touched, not from when it registered.
    @Test func theHourRunsFromItsLastTask() throws {
        let project = Project(name: "Sleeper Train")
        let old = try idle(1, on: project.id, since: hour * 5)
        let justFinished = task("Done", on: project.id, state: .done, agentID: old.id, ago: 60)
        let snapshot = Snapshot(projects: [project], tasks: [justFinished], agents: [old])
        #expect(Sweep.idleAgentsToStop(in: snapshot, messages: [], now: .now).isEmpty)
    }

    /// Work waiting means a poke is the right move, not a stop.
    @Test func notWhileItsBacklogHasWork() throws {
        let project = Project(name: "Sleeper Train")
        let spent = try idle(1, on: project.id, since: hour * 2)
        let waiting = task("Next", on: project.id, state: .backlog)
        #expect(Sweep.idleAgentsToStop(in: Snapshot(projects: [project], tasks: [waiting], agents: [spent]),
                                       messages: [], now: .now).isEmpty)
    }

    /// Blocked is busy: it is waiting on something and the factory clears its own blocks.
    @Test func notWhileItHoldsABlockedTask() throws {
        let project = Project(name: "Sleeper Train")
        let spent = try idle(1, on: project.id, since: hour * 2)
        let stuck = task("Stuck", on: project.id, state: .blocked, agentID: spent.id, ago: hour * 2)
        #expect(Sweep.idleAgentsToStop(in: Snapshot(projects: [project], tasks: [stuck], agents: [spent]),
                                       messages: [], now: .now).isEmpty)
    }

    /// It asked a question and is waiting for the answer, which is what it should do.
    @Test func notWhileItHasAQuestionOpen() throws {
        let project = Project(name: "Sleeper Train")
        let spent = try idle(1, on: project.id, since: hour * 2)
        var asked = Escalation(projectID: project.id, question: "Which way?",
                               options: [.init(title: "A"), .init(title: "B")])
        asked.agentID = spent.id
        #expect(Sweep.idleAgentsToStop(in: Snapshot(projects: [project], escalations: [asked], agents: [spent]),
                                       messages: [], now: .now).isEmpty)
    }

    @Test func notWhileSomethingIsAboutToBeSaidToIt() throws {
        let project = Project(name: "Sleeper Train")
        let spent = try idle(1, on: project.id, since: hour * 2)
        let mail = AgentMessage(recipientID: spent.id, from: "Alex", subject: "Nudge",
                                contents: "x", sent: .now)
        #expect(Sweep.idleAgentsToStop(in: Snapshot(projects: [project], agents: [spent]),
                                       messages: [mail], now: .now).isEmpty)
    }

    /// No backlog to be empty, and the person started it for something of their own.
    @Test func anAgentOnNoProjectIsLeftAlone() throws {
        let loose = try idle(1, on: nil, since: hour * 5)
        #expect(Sweep.idleAgentsToStop(in: Snapshot(agents: [loose]), messages: [], now: .now).isEmpty)
    }

    /// Nothing here to stop: it registered from somewhere else and never told us a process.
    @Test func anExternalAgentIsNotStopped() {
        let project = Project(name: "Sleeper Train")
        let outside = Agent(number: 9, projectID: project.id,
                            registered: Date().addingTimeInterval(-60 * 60 * 5))
        #expect(Sweep.idleAgentsToStop(in: Snapshot(projects: [project], agents: [outside]),
                                       messages: [], now: .now).isEmpty)
    }
}
