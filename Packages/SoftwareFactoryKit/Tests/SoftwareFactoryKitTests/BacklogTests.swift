import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct BacklogTests {
    let p = "/p"

    func task(_ title: String, rank: Int, state: FactoryTask.State = .backlog, updated: TimeInterval = 0) -> FactoryTask {
        var t = FactoryTask(projectID: p, title: title, state: state, rank: rank, created: Date(timeIntervalSince1970: 0))
        t.updated = Date(timeIntervalSince1970: updated)
        return t
    }

    @Test func orderIsInProgressThenBacklogThenParkedThenDoneNewestFirst() {
        let all = [
            task("done old", rank: 0, state: .done, updated: 10),
            task("second", rank: 2),
            task("parked", rank: 0, state: .parked),
            task("done new", rank: 1, state: .done, updated: 20),
            task("first", rank: 1),
            task("now", rank: 5, state: .inProgress),
            FactoryTask(projectID: "/other", title: "elsewhere", rank: 0),
        ]
        #expect(Backlog.tasks(for: p, in: all).map(\.title) == ["now", "first", "second", "parked", "done new", "done old"])
        let stuck = Backlog.block(task("stuck", rank: 9), on: .init(kind: .person, why: "alex"))
        #expect(Backlog.tasks(for: p, in: all + [stuck]).first?.title == "stuck")   // blocked above in progress
        #expect(Backlog.next(for: p, in: all)?.title == "first")
        // Parked tasks sit out of the reordering.
        let changed = Backlog.move(in: Backlog.tasks(for: p, in: all), from: IndexSet(integer: 2), to: 0)
        #expect(changed.first?.title == "second")
        #expect(!changed.contains { $0.title == "parked" })
        #expect(Backlog.personMaySet == [.backlog, .parked])
        #expect(Backlog.set(task("a", rank: 0, state: .inProgress), to: .parked).agentID == nil)
    }

    @Test func visibleKeepsThreeDoneAndTenParkedInBlocks() {
        var all = [task("open", rank: 0), task("now", rank: 1, state: .inProgress)]
        for n in 0..<8 { all.append(task("done \(n)", rank: 9, state: .done, updated: TimeInterval(n))) }
        for n in 0..<12 { all.append(task("parked \(n)", rank: n, state: .parked)) }
        let shown = Backlog.visible(for: p, in: all)
        #expect(shown.filter { $0.state == .done }.map(\.title) == ["done 7", "done 6", "done 5"])
        #expect(shown.filter { $0.state == .parked }.count == 10)
        #expect(shown.filter { $0.state == .parked }.first?.title == "parked 0")
        let blocks = Backlog.blocks(shown)
        #expect(blocks.map(\.state) == [.inProgress, .backlog, .parked, .done])
        #expect(blocks[0].tasks.map(\.title) == ["now"])
        #expect(Backlog.blocks([Backlog.block(task("b", rank: 0), on: .init(kind: .other, why: "x")), task("now", rank: 1, state: .inProgress)]).map(\.state) == [.blocked, .inProgress])
        #expect(Backlog.blocks([]).isEmpty)
    }

    @Test func blockedIsNotNextAndClearsOnItsOwn() throws {
        var e = Escalation(projectID: p, question: "?", options: [.init(title: "A"), .init(title: "B")])
        let waiting = Backlog.block(task("waiting", rank: 0), on: .init(kind: .decision, id: e.id, why: "which one"))
        let other = task("other", rank: 1)
        let prerequisite = task("first do this", rank: 2, state: .done, updated: 5)
        let after = Backlog.block(task("after", rank: 3), on: .init(kind: .task, id: prerequisite.id, why: "needs the first"))
        let onAlex = Backlog.block(task("on alex", rank: 4), on: .init(kind: .person, why: "register the container"))
        let all = [waiting, other, prerequisite, after, onAlex]

        #expect(Backlog.next(for: p, in: all)?.title == "other")
        #expect(Backlog.tasks(for: p, in: all).map(\.title) == ["waiting", "after", "on alex", "other", "first do this"])
        #expect(!Backlog.move(in: Backlog.tasks(for: p, in: all), from: IndexSet(integer: 0), to: 1).contains { $0.state == .blocked })

        // Nothing has cleared yet except the task block.
        var cleared = Sweep.unblocked(in: Snapshot(tasks: all, escalations: [e]), now: Date(timeIntervalSince1970: 9))
        #expect(cleared.map(\.title) == ["after"])
        #expect(cleared[0].state == .backlog)
        #expect(cleared[0].blockers.isEmpty)
        #expect(cleared[0].note.contains("unblocked, first do this is done"))

        try e.decide(e.options[1])
        cleared = Sweep.unblocked(in: Snapshot(tasks: all, escalations: [e]), now: Date(timeIntervalSince1970: 9))
        #expect(Set(cleared.map(\.title)) == ["waiting", "after"])
        #expect(cleared.first { $0.title == "waiting" }?.note.contains("→ B") == true)
        // A person clears it by hand, never the sweep.
        #expect(!cleared.contains { $0.title == "on alex" })
        #expect(Backlog.set(onAlex, to: .backlog).blockers.isEmpty)
    }

    @Test func aTaskWaitingOnTwoThingsClearsWhenTheLastDoes() throws {
        var e = Escalation(projectID: p, question: "?", options: [.init(title: "A")])
        var two = Backlog.block(task("two", rank: 0), on: .init(kind: .decision, id: e.id, why: "the answer"))
        two = Backlog.block(two, on: .init(kind: .person, why: "the stand-down lifts"))
        two = Backlog.block(two, on: .init(kind: .person, why: "the stand-down lifts"))   // twice is once
        #expect(two.blockers.count == 2)
        #expect(two.blockedWhy == "the answer; the stand-down lifts")

        try e.decide(e.options[0])
        let swept = Sweep.unblocked(in: Snapshot(tasks: [two], escalations: [e]), now: .now)
        #expect(swept.count == 1)
        #expect(swept[0].state == .blocked)                       // still waiting on the person
        #expect(swept[0].blockers.map(\.why) == ["the stand-down lifts"])
        #expect(swept[0].note.contains("cleared, decided ? → A"))
        // Nothing left to clear on its own: the sweep leaves it alone now.
        #expect(Sweep.unblocked(in: Snapshot(tasks: swept, escalations: [e]), now: .now).isEmpty)
    }

    @Test func aDecisionReplacesTheWaitOnThePersonItAsks() throws {
        var e = Escalation(projectID: p, question: "Which container?", options: [.init(title: "A")])
        // The lead's flow: block on the person, raise the question, block on the decision.
        var row = Backlog.block(task("row", rank: 0), on: .init(kind: .person, why: "Needs Alex in the browser"))
        row = Backlog.block(row, on: .init(kind: .decision, id: e.id, why: "which container"))
        #expect(row.blockers.map(\.kind) == [.decision])

        // A row blocked before the rule carries both; the answer clears both.
        var old = task("old", rank: 1)
        old.state = .blocked
        old.blockers = [.init(kind: .person, why: "Needs Alex in the browser"), .init(kind: .decision, id: e.id, why: "which container")]
        try e.decide(e.options[0])
        let swept = Sweep.unblocked(in: Snapshot(tasks: [row, old], escalations: [e]), now: .now)
        #expect(swept.map(\.title) == ["row", "old"])
        #expect(swept.allSatisfy { $0.state == .backlog && $0.blockers.isEmpty })
        #expect(swept[1].note.contains("and with it the wait on Needs Alex in the browser"))
    }

    @Test func clearingOneBlockerByNumberOrWords() throws {
        var t = Backlog.block(task("t", rank: 0), on: .init(kind: .other, why: "the measurement finishes"))
        t = Backlog.block(t, on: .init(kind: .person, why: "the stand-down lifts"))
        let one = try Backlog.unblock(t, matching: "stand-down")
        #expect(one.state == .blocked)
        #expect(one.blockers.map(\.why) == ["the measurement finishes"])
        #expect(one.note.contains("cleared by hand: the stand-down lifts"))
        let none = try Backlog.unblock(one, matching: "1")
        #expect(none.state == .backlog)
        #expect(none.blockers.isEmpty)
        #expect(throws: Backlog.UnblockError.noMatch) { try Backlog.unblock(t, matching: "zzz") }
        var same = Backlog.block(task("s", rank: 0), on: .init(kind: .other, why: "wait a"))
        same = Backlog.block(same, on: .init(kind: .other, why: "wait b"))
        #expect(throws: Backlog.UnblockError.ambiguous) { try Backlog.unblock(same, matching: "wait") }
    }

    @Test func removingKeepsTheRecordAndMovingSaysWhereFrom() throws {
        let gone = Backlog.remove(task("gone", rank: 0), why: "filed twice")
        #expect(gone.removed != nil)
        #expect(gone.note.contains("removed: filed twice"))
        let store = try temporaryStore()
        try store.save(gone)
        try store.save(task("kept", rank: 1))
        #expect(try store.load().tasks.map(\.title) == ["kept"])
        #expect(try store.loadRemovedTasks().map(\.title) == ["gone"])

        let elsewhere = Project(name: "Elsewhere", id: "/Users/alex/Elsewhere")
        let moved = Backlog.move(task("wrong place", rank: 0), to: elsewhere, from: Project(name: "Here", id: p), in: [FactoryTask(projectID: elsewhere.id, title: "x", rank: 4)])
        #expect(moved.projectID == elsewhere.id)
        #expect(moved.rank == 5)
        #expect(moved.note.contains("moved here from Here"))
    }

    @Test func aVersionOneBlockerStillReads() throws {
        let json = """
        {"version":1,"id":"\(UUID().uuidString)","projectID":"/p","title":"old","kind":"feature","state":"blocked","rank":0,"note":"",
         "blocker":{"kind":"person","why":"alex"},"created":"2026-09-12T10:00:00Z","updated":"2026-09-12T10:00:00Z"}
        """
        let t = try FileStore.decoder.decode(FactoryTask.self, from: Data(json.utf8))
        #expect(t.blockers.map(\.why) == ["alex"])
        let again = try FileStore.decoder.decode(FactoryTask.self, from: FileStore.encoder.encode(t))
        #expect(again.blockers == t.blockers)
    }

    @Test func nextRankFollowsTheProject() {
        let all = [task("a", rank: 4), FactoryTask(projectID: "/other", title: "b", rank: 99)]
        #expect(Backlog.nextRank(for: p, in: all) == 5)
        #expect(Backlog.nextRank(for: "/new", in: all) == 0)
    }

    @Test func topRankGoesFirstAndDoneDoesNotCount() {
        let all = [task("a", rank: 2), task("b", rank: 5), task("old", rank: -9, state: .done)]
        #expect(Backlog.topRank(for: p, in: all) == 1)
        #expect(Backlog.topRank(for: "/new", in: all) == 0)
        #expect(Backlog.rank(for: .top, projectID: p, in: all) == 1)
        #expect(Backlog.rank(for: .bottom, projectID: p, in: all) == 6)
        let first = task("new", rank: Backlog.topRank(for: p, in: all))
        #expect(Backlog.tasks(for: p, in: all + [first]).first?.title == "new")
    }

    @Test func stateForPositionIsParkedOnlyWhenAskedForParked() {
        #expect(Backlog.state(for: .top) == .backlog)
        #expect(Backlog.state(for: .bottom) == .backlog)
        #expect(Backlog.state(for: .parked) == .parked)
    }

    @Test func moveRenumbersOnlyWhatChanged() {
        let all = [task("a", rank: 0), task("b", rank: 1), task("c", rank: 2), task("done", rank: 3, state: .done)]
        let changed = Backlog.move(in: all, from: IndexSet(integer: 2), to: 0)
        #expect(changed.map(\.title) == ["c", "a", "b"])
        #expect(changed.map(\.rank) == [0, 1, 2])
    }

    @Test func placeAboveMovesOneTask() {
        let all = [task("a", rank: 0), task("b", rank: 1), task("c", rank: 2)]
        let changed = Backlog.place(all[2], above: all[0], in: all)
        #expect(changed.map { "\($0.title)\($0.rank)" } == ["c0", "a1", "b2"])
    }

    @Test func placingATaskAboveItselfChangesNothing() {
        let all = [task("a", rank: 0), task("b", rank: 1)]
        #expect(Backlog.place(all[0], above: all[0], in: all).isEmpty)
    }

    @Test func startingRecordsTheAgentAndBacklogForgetsIt() {
        let id = UUID()
        let started = Backlog.set(task("a", rank: 0), to: .inProgress, agentID: id)
        #expect(started.state == .inProgress)
        #expect(started.agentID == id)
        let back = Backlog.set(started, to: .backlog)
        #expect(back.agentID == nil)
    }

    @Test func currentIsTheNewestInProgressTask() {
        let all = [task("older", rank: 0, state: .inProgress, updated: 1), task("newer", rank: 1, state: .inProgress, updated: 2)]
        #expect(Backlog.current(for: p, in: all)?.title == "newer")
        #expect(Backlog.current(for: "/none", in: all) == nil)
    }
}

@Suite struct DashboardTests {
    let now = Date(timeIntervalSince1970: 10_000)

    @Test func countsAndActivity() {
        let a = Project(name: "a", id: "/a")
        var fresh = Agent(name: "one", projectID: "/a", registered: now.addingTimeInterval(-500))
        fresh.lastSeen = now.addingTimeInterval(-10)
        var quiet = Agent(name: "two", projectID: "/b", registered: now.addingTimeInterval(-500))
        quiet.lastSeen = now.addingTimeInterval(-900)
        var gone = Agent(name: "three", projectID: "/c", registered: now.addingTimeInterval(-500))
        gone.deregistered = now
        let snap = Snapshot(
            projects: [a],
            tasks: [
                FactoryTask(projectID: a.id, title: "on it", state: .inProgress, rank: 0),
                FactoryTask(projectID: a.id, title: "later", rank: 1),
                FactoryTask(projectID: "/b", title: "also on it", state: .inProgress, rank: 0),
            ],
            escalations: [Escalation(projectID: a.id, question: "?", options: [.init(title: "x"), .init(title: "y")], agentID: fresh.id)],
            agents: [fresh, quiet, gone]
        )
        let d = Dashboard.make(snapshot: snap, now: now)

        #expect(d.inProgress == 2)
        #expect(d.openEscalations.count == 1)
        #expect(d.projects.map(\.project.name) == ["a", "b"])   // /c's agent has left
        #expect(d.projects[0].activity == .working)
        #expect(d.projects[0].doing == "on it")
        #expect(d.projects[0].backlogCount == 1)
        #expect(d.projects[0].openEscalations == 1)
        #expect(d.projects[1].activity == .waiting)
        #expect(d.projects[1].doing == "also on it")
        #expect(d.workingCount == 1)
        #expect(d.agents.map(\.agent.name) == ["one", "two"])
        #expect(d.agents[0].waitingOnYou)
        #expect(!d.agents[1].waitingOnYou)
    }

    @Test func aProjectOnHoldShowsItsNameAndNothingElse() {
        var held = Project(name: "held", id: "/held")
        held.onHold = true
        var agent = Agent(name: "one", projectID: held.id, registered: now)
        agent.lastSeen = now
        var task = FactoryTask(projectID: held.id, title: "still going", rank: 1)
        task.state = .inProgress
        task.agentID = agent.id
        agent.taskID = task.id
        agent.note = "on it"
        let question = Escalation(projectID: held.id, question: "q", options: [.init(title: "a")], agentID: agent.id, raisedBy: "one", raised: now)
        let live = Project(name: "live", id: "/live")
        var liveTask = FactoryTask(projectID: live.id, title: "live one", rank: 1)
        liveTask.state = .inProgress
        let d = Dashboard.make(snapshot: Snapshot(projects: [held, live], tasks: [task, liveTask], escalations: [question], agents: [agent]), now: now)
        #expect(d.projects.map(\.project.id) == [live.id, held.id])
        let h = d.projects[1]
        #expect(h.activity == .idle)
        #expect(h.doing == nil)
        #expect(h.inProgressCount == 0 && h.blockedCount == 0 && h.backlogCount == 0 && h.doneCount == 0)
        #expect(h.openEscalations == 1)
        #expect(d.inProgress == 1)
        // The agent is still on the floor; it is the project that is quiet.
        #expect(d.agents.map(\.agent.name) == ["one"])
    }

    @Test func aCommentIsSignedDatedAndAppended() {
        var task = FactoryTask(projectID: "/a", title: "t", rank: 1, note: "first line")
        let day = Date(timeIntervalSince1970: 1_789_259_200)  // 12 Sep 2026
        task = Backlog.comment(on: task, "  needs the phone  ", by: "Alex", at: day)
        #expect(task.note.hasPrefix("first line\nAlex, 12 Sep") && task.note.hasSuffix("2026: needs the phone"))
        #expect(task.updated == day)
        let same = Backlog.comment(on: task, "   ", by: "Alex", at: day.addingTimeInterval(9))
        #expect(same.note == task.note)
        let fresh = Backlog.comment(on: FactoryTask(projectID: "/a", title: "t", rank: 1), "hi", by: "one", at: day)
        #expect(fresh.note.hasPrefix("one, 12 Sep") && fresh.note.hasSuffix(": hi"))
    }

    @Test func idleProjectWithNothingOnShowsNothing() {
        let d = Dashboard.make(snapshot: Snapshot(projects: [Project(name: "a", id: "/a")]), now: now)
        #expect(d.projects[0].activity == .idle)
        #expect(d.projects[0].doing == nil)
    }
}
