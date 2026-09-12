import Foundation
import Testing
@testable import ForemanKit

func temporaryStore() throws -> FileStore {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "ForemanKitTests-\(UUID().uuidString)")
    return try FileStore(root: root)
}

@Suite struct StoreTests {
    @Test func roundTripsEveryKindOfRecord() throws {
        let store = try temporaryStore()
        // ISO 8601 keeps whole seconds, so records are made on a whole second.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let project = Project(path: "/Users/alex/Where/", added: now)
        #expect(project.id == "/Users/alex/Where")
        #expect(project.name == "Where")
        let item = WorkItem(projectID: project.id, title: "Fix it", kind: .bug, rank: 3, note: "why", created: now)
        var escalation = Escalation(
            projectID: project.id, question: "Which?", options: [.init(title: "A", recommended: true), .init(title: "B")],
            raised: now)
        try escalation.decide(escalation.options[1], at: now)

        try store.save(project)
        try store.save(item)
        try store.save(escalation)

        let snap = try store.load()
        #expect(snap.projects == [project])
        #expect(snap.items == [item])
        #expect(snap.escalations == [escalation])
        #expect(snap.escalations[0].chosen?.title == "B")
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
        let item = WorkItem(projectID: "/p", title: "t", rank: 0)
        try store.save(item)
        try store.delete(item)
        #expect(try store.load().items.isEmpty)
    }

    @Test func storeRootHonoursTheEnvironment() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let root = FileStore.defaultRoot(home: home)
        if ProcessInfo.processInfo.environment["FOREMAN_STORE"] == nil {
            #expect(root.path == "/Users/someone/Library/Group Containers/\(FileStore.appGroup)/Store")
        }
    }
}

@Suite struct EscalationTests {
    @Test func decidingRecordsTheChoiceAndWhen() throws {
        var e = Escalation(projectID: "/p", question: "q", options: [.init(title: "A", recommended: true), .init(title: "B")])
        #expect(e.isOpen)
        #expect(e.recommended?.title == "A")
        let when = Date(timeIntervalSince1970: 1000)
        try e.decide(e.options[0], at: when)
        #expect(!e.isOpen)
        #expect(e.decided == when)
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
