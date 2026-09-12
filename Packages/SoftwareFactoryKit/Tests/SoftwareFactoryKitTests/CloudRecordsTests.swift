import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct CloudRecordsTests {
    @Test func everyRecordRoundTrips() {
        let snap = SampleData.snapshot(now: wholeSecond())
        let encoded = CloudRecords.encode(snap)
        #expect(encoded.count == snap.projects.count + snap.tasks.count + snap.escalations.count + snap.agents.count)
        #expect(Set(encoded.map(\.recordName)).count == encoded.count)
        let back = CloudRecords.decode(encoded)
        #expect(Set(back.projects) == Set(snap.projects))
        #expect(Set(back.tasks) == Set(snap.tasks))
        #expect(Set(back.escalations) == Set(snap.escalations))
        #expect(Set(back.agents) == Set(snap.agents))
    }

    @Test func diffSendsOnlyWhatChanged() {
        var snap = SampleData.snapshot(now: wholeSecond())
        let before = CloudRecords.encode(snap)
        #expect(CloudRecords.diff(from: before, to: before).isEmpty)

        snap.tasks[0].title = "renamed"
        let removed = snap.agents.removeLast()
        snap.projects.append(Project(name: "new", id: "/new"))
        let after = CloudRecords.encode(snap)
        let diff = CloudRecords.diff(from: before, to: after)
        #expect(diff.save.map(\.type).sorted() == ["Project", "Task"])
        #expect(diff.delete == ["Agent-\(removed.id.uuidString)"])

        // A first push, with nothing known, sends everything.
        #expect(CloudRecords.diff(from: [], to: after).save.count == after.count)
    }

    @Test func adoptsDecisionsMadeElsewhere() throws {
        let open = Escalation(projectID: "/p", question: "q", options: [.init(title: "A"), .init(title: "B")])
        var decidedThere = open
        try decidedThere.decide(open.options[1], by: "alex, phone")
        var alreadyMine = Escalation(projectID: "/p", question: "r", options: [.init(title: "A")])
        try alreadyMine.decide(alreadyMine.options[0], by: "alex")
        var theirsOfMine = alreadyMine
        theirsOfMine.decision?.by = "alex, phone"
        var stranger = Escalation(projectID: "/p", question: "s", options: [.init(title: "A")])
        try stranger.decide(stranger.options[0], by: "alex, phone")

        let adopted = CloudRecords.decisionsToAdopt(local: [open, alreadyMine], cloud: [decidedThere, theirsOfMine, stranger])
        #expect(adopted.count == 1)
        #expect(adopted[0].id == open.id)
        #expect(adopted[0].decision?.by == "alex, phone")
        #expect(adopted[0].chosen?.title == "B")
    }

    @Test func aDecisionForAnOptionWeDoNotHaveIsIgnored() throws {
        let open = Escalation(projectID: "/p", question: "q", options: [.init(title: "A")])
        var odd = open
        odd.options.append(.init(title: "Z"))
        try odd.decide(odd.options[1])
        #expect(CloudRecords.decisionsToAdopt(local: [open], cloud: [odd]).isEmpty)
    }

    @Test func aTaskAddedAwayFromTheMacIsAdopted() {
        let mine = FactoryTask(projectID: "/p", title: "already here", rank: 0)
        let addedOnThePhone = FactoryTask(projectID: "/p", title: "added away from the Mac", rank: 1)
        let adopted = CloudRecords.tasksToAdopt(local: [mine], cloud: [mine, addedOnThePhone])
        #expect(adopted.map(\.id) == [addedOnThePhone.id])
    }
}
