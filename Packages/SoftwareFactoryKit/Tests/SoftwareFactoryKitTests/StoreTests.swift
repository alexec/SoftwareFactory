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

    @Test func anOptionFromElsewhereIsRefused() {
        var e = Escalation(projectID: "/p", question: "q", options: [.init(title: "A"), .init(title: "B")])
        #expect(throws: EscalationError.unknownOption) {
            try e.decide(.init(title: "C"))
        }
    }
}

@Suite struct AgentTests {
    @Test func quietAfterTwoMinutes() {
        let now = Date()
        var a = Agent(name: "x", projectID: nil, registered: now.addingTimeInterval(-1000))
        a.lastSeen = now.addingTimeInterval(-30)
        #expect(a.isWorking(now: now))
        a.lastSeen = now.addingTimeInterval(-300)
        #expect(!a.isWorking(now: now))
        a.lastSeen = now
        a.deregistered = now
        #expect(!a.isOnTheFloor)
        #expect(!a.isWorking(now: now))
    }
}
