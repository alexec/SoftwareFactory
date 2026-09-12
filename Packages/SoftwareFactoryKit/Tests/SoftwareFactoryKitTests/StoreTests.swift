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
        let project = Project(path: "/Users/alex/Where/", added: now)
        #expect(project.id == "/Users/alex/Where")
        #expect(project.name == "Where")
        let task = FactoryTask(projectID: project.id, title: "Fix it", kind: .bug, rank: 3, note: "why", created: now)
        var escalation = Escalation(
            projectID: project.id, question: "Which?", options: [.init(title: "A", recommended: true), .init(title: "B")],
            raised: now)
        try escalation.decide(escalation.options[1], at: now)
        let agent = Agent(name: "agent-1", projectID: project.id, registered: now)

        try store.save(project)
        try store.save(task)
        try store.save(escalation)
        try store.save(agent)

        let snap = try store.load()
        #expect(snap.projects == [project])
        #expect(snap.tasks == [task])
        #expect(snap.escalations == [escalation])
        #expect(snap.agents == [agent])
        #expect(snap.escalations[0].chosen?.title == "B")
        #expect(try #require(store.escalation(escalation.id)) == escalation)
    }

    @Test func everyRecordCarriesAVersionAndReadsWithoutOne() throws {
        let store = try temporaryStore()
        let project = Project(path: "/a")
        try store.save(project)
        let file = store.root.appending(path: "projects/\(FileStore.fileName(forProject: project.id)).json")
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(text.contains("\"version\" : \(Records.version)"))

        // An older writer never wrote the field; the record still reads, as version 1.
        var stripped = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        stripped["version"] = nil
        try JSONSerialization.data(withJSONObject: stripped).write(to: file)
        let back = try #require(try store.load().projects.first)
        #expect(back.version == 1)
        #expect(back.id == "/a")

        #expect(FactoryTask(projectID: "/a", title: "t", rank: 0).version == Records.version)
        #expect(Escalation(projectID: "/a", question: "q", options: []).version == Records.version)
        #expect(Agent(name: "a", projectID: nil).version == Records.version)
        #expect(Resource(name: "r").version == Records.version)
        #expect(Lease(resourceID: UUID(), agentID: UUID(), why: "", since: .now, until: .now).version == Records.version)
    }

    @Test func sameFolderLandsInOneFile() throws {
        let store = try temporaryStore()
        try store.save(Project(path: "/a/b", name: "first"))
        try store.save(Project(path: "/a/b/", name: "second"))
        let snap = try store.load()
        #expect(snap.projects.count == 1)
        #expect(snap.projects[0].name == "second")
    }

    @Test func skipsAFileItCannotRead() throws {
        let store = try temporaryStore()
        try store.save(Project(path: "/a/b"))
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
}

@Suite struct AgentTests {
    @Test func goneAfterThreeMissedCheckIns() {
        let now = Date()
        var silent = Agent(name: "silent", projectID: nil, registered: now.addingTimeInterval(-3600))
        silent.lastSeen = now.addingTimeInterval(-61 * 60)
        var talking = Agent(name: "talking", projectID: nil, registered: now.addingTimeInterval(-3600))
        talking.lastSeen = now.addingTimeInterval(-60)
        var left = Agent(name: "left", projectID: nil, registered: now.addingTimeInterval(-3600))
        left.lastSeen = now.addingTimeInterval(-3600)
        left.deregistered = now.addingTimeInterval(-1800)
        let phone = Resource(name: "iPhone")
        let held = Lease(resourceID: phone.id, agentID: silent.id, why: "", since: now.addingTimeInterval(-1000), until: now.addingTimeInterval(1000))
        let snap = Snapshot(agents: [silent, talking, left], resources: [phone], leases: [held])
        let changes = Sweep.goneAgents(in: snap, now: now)
        #expect(changes.agents.map(\.name) == ["silent"])
        #expect(changes.agents[0].deregistered == now)
        #expect(changes.leases.map(\.id) == [held.id])
        #expect(changes.leases[0].released == now)
        #expect(Sweep.goneAgents(in: Snapshot(agents: [talking, left]), now: now).isEmpty)
    }

    @Test func quietAfterTwoMinutes() {
        let now = Date()
        var a = Agent(name: "x", projectID: nil, registered: now.addingTimeInterval(-1000))
        a.lastSeen = now.addingTimeInterval(-30)
        #expect(a.isWorking(now: now))
        a.lastSeen = now.addingTimeInterval(-11 * 60)
        #expect(!a.isWorking(now: now))
        a.lastSeen = now
        a.deregistered = now
        #expect(!a.isOnTheFloor)
        #expect(!a.isWorking(now: now))
    }
}

@Suite struct EscalationsViewTests {
    @Test func openInFullThenTheNewestFewDecided() throws {
        let t0 = Date(timeIntervalSince1970: 1000)
        func q(_ n: Int, decidedAt: TimeInterval? = nil) throws -> Escalation {
            var e = Escalation(projectID: "/p", question: "q\(n)", options: [.init(title: "A"), .init(title: "B")], raised: t0.addingTimeInterval(TimeInterval(n)))
            if let decidedAt { try e.decide(e.options[0], at: t0.addingTimeInterval(decidedAt)) }
            return e
        }
        let all = [try q(5), try q(1), try q(2, decidedAt: 50), try q(3, decidedAt: 70), try q(4, decidedAt: 60), try q(6, decidedAt: 10),
                   Escalation(projectID: "/other", question: "x", options: [.init(title: "A")])]
        let shown = Escalations.visible(for: "/p", in: all, recentDecided: 3)
        #expect(shown.open.map(\.question) == ["q1", "q5"])
        #expect(shown.decided.map(\.question) == ["q3", "q4", "q2"])
    }
}
