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
            task("done old", rank: 0, state: .succeeded, updated: 10),
            task("second", rank: 2),
            task("parked", rank: 0, state: .parked),
            task("done new", rank: 1, state: .succeeded, updated: 20),
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

    /// A task in an agent's name is that agent's next piece of work, and nobody else's.
    @Test func anAssignedTaskGoesToThatAgentAndIsPassedOverByOthers() {
        let mine = UUID(), theirs = UUID()
        let day = Date(timeIntervalSince1970: 1_789_259_200)
        let first = task("first", rank: 0)
        var second = task("second", rank: 1)
        second = Backlog.assign(second, to: mine, named: "A12", by: "Alex", at: day)
        var third = task("third", rank: 2)
        third = Backlog.assign(third, to: theirs, named: "A13", by: "Alex", at: day)
        let all = [first, second, third]

        #expect(second.state == .backlog)                       // still waiting, not claimed
        #expect(second.note.hasSuffix("assigned to A12"))
        #expect(Backlog.next(for: p, in: all, agentID: mine)?.title == "second")
        #expect(Backlog.next(for: p, in: all, agentID: theirs)?.title == "third")
        // Anyone else gets the top task nobody's name is on.
        #expect(Backlog.next(for: p, in: all, agentID: UUID())?.title == "first")
        #expect(Backlog.next(for: p, in: all)?.title == "first")

        // Taking the name off puts it back in the open pile.
        let freed = Backlog.assign(third, to: nil, named: nil, by: "Alex", at: day)
        #expect(freed.agentID == nil)
        #expect(freed.note.hasSuffix("unassigned"))
        #expect(Backlog.next(for: p, in: [first, freed], agentID: UUID())?.title == "first")
        // Assigning what is already assigned to them changes nothing.
        #expect(Backlog.assign(second, to: mine, named: "A12", by: "Alex", at: day) == second)
    }

    /// The person takes a task back from an agent that gave up or went quiet.
    @Test func takingAnInProgressTaskBackClearsTheAgent() {
        var running = task("running", rank: 0, state: .inProgress)
        running.agentID = UUID()
        let back = Backlog.set(running, to: .backlog)
        #expect(back.state == .backlog)
        #expect(back.agentID == nil)
        #expect(Backlog.personMaySet.contains(.backlog))
    }

    @Test func visibleKeepsThreeDoneAndTenParkedInBlocks() {
        var all = [task("open", rank: 0), task("now", rank: 1, state: .inProgress)]
        for n in 0..<8 { all.append(task("done \(n)", rank: 9, state: .succeeded, updated: TimeInterval(n))) }
        for n in 0..<12 { all.append(task("parked \(n)", rank: n, state: .parked)) }
        let shown = Backlog.visible(for: p, in: all)
        #expect(shown.filter { $0.state == .succeeded }.map(\.title) == ["done 7", "done 6", "done 5"])
        #expect(shown.filter { $0.state == .parked }.count == 10)
        #expect(shown.filter { $0.state == .parked }.first?.title == "parked 0")
        let blocks = Backlog.blocks(shown)
        #expect(blocks.map(\.state) == [.inProgress, .backlog, .parked, .succeeded])
        #expect(blocks[0].tasks.map(\.title) == ["now"])
        #expect(Backlog.blocks([Backlog.block(task("b", rank: 0), on: .init(kind: .other, why: "x")), task("now", rank: 1, state: .inProgress)]).map(\.state) == [.blocked, .inProgress])
        #expect(Backlog.blocks([]).isEmpty)
    }

    /// A failure is not capped like a success. Three tasks succeeding after one failed used
    /// to take the failure off the page, which is the page dropping the one task on the
    /// project that somebody has to decide something about. (T509.)
    @Test func aFailedTaskIsAlwaysShownAndSitsAboveTheBacklog() {
        var all = [task("open", rank: 0), task("went wrong", rank: 1, state: .failed, updated: 0)]
        for n in 0..<8 { all.append(task("done \(n)", rank: 9, state: .succeeded, updated: TimeInterval(n + 1))) }
        let shown = Backlog.visible(for: p, in: all)
        #expect(shown.filter { $0.state == .failed }.map(\.title) == ["went wrong"])
        #expect(shown.filter { $0.state == .succeeded }.count == 3)
        #expect(Backlog.blocks(shown).map(\.state) == [.failed, .backlog, .succeeded])
    }

    /// Several failures are all of them: there is no reading of "the three most recent" that
    /// makes sense for work that went wrong.
    @Test func everyFailedTaskIsShown() {
        var all: [FactoryTask] = []
        for n in 0..<6 { all.append(task("went wrong \(n)", rank: n, state: .failed, updated: TimeInterval(n))) }
        #expect(Backlog.visible(for: p, in: all).count == 6)
    }

    @Test func blockedIsNotNextAndClearsOnItsOwn() throws {
        var e = Escalation(projectID: p, question: "?", options: [.init(title: "A"), .init(title: "B")])
        let waiting = Backlog.block(task("waiting", rank: 0), on: .init(kind: .decision, id: e.id, why: "which one"))
        let other = task("other", rank: 1)
        let prerequisite = task("first do this", rank: 2, state: .succeeded, updated: 5)
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

    @Test func removingKeepsTheRecord() throws {
        let gone = Backlog.remove(task("gone", rank: 0), why: "filed twice")
        #expect(gone.removed != nil)
        #expect(gone.note.contains("removed: filed twice"))
        let store = try temporaryStore()
        try store.save(gone)
        try store.save(task("kept", rank: 1))
        #expect(try store.load().tasks.map(\.title) == ["kept"])
        #expect(try store.loadRemovedTasks().map(\.title) == ["gone"])
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
        let all = [task("a", rank: 2), task("b", rank: 5), task("old", rank: -9, state: .succeeded)]
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
        let all = [task("a", rank: 0), task("b", rank: 1), task("c", rank: 2), task("done", rank: 3, state: .succeeded)]
        let changed = Backlog.move(in: all, from: IndexSet(integer: 2), to: 0)
        #expect(changed.map(\.title) == ["c", "a", "b"])
        #expect(changed.map(\.rank) == [0, 1, 2])
    }

    @Test func parkedItemsReorderWithoutTouchingTheBacklog() {
        let all = [
            task("backlog-a", rank: 0), task("parked-a", rank: 10, state: .parked),
            task("parked-b", rank: 11, state: .parked), task("parked-c", rank: 12, state: .parked),
        ]
        let changed = Backlog.move(in: all, from: IndexSet(integer: 2), to: 0, states: [.parked])
        #expect(changed.map(\.title) == ["parked-c", "parked-a", "parked-b"])
        #expect(changed.allSatisfy { $0.state == .parked })
    }

    @Test func placeAboveMovesOneTask() {
        let all = [task("a", rank: 0), task("b", rank: 1), task("c", rank: 2)]
        let changed = Backlog.place(all[2], above: all[0], in: all)
        #expect(changed.map { "\($0.title)\($0.rank)" } == ["c0", "a1", "b2"])
    }

    @Test func placeAboveWithinParkedLeavesTheBacklogAlone() {
        let all = [
            task("backlog-a", rank: 0),
            task("parked-a", rank: 10, state: .parked), task("parked-b", rank: 11, state: .parked),
        ]
        let changed = Backlog.place(all[2], above: all[1], in: all, states: [.parked])
        #expect(changed.map(\.title) == ["parked-b", "parked-a"])
        #expect(changed.allSatisfy { $0.state == .parked })
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
        var fresh = Agent(number: 1, projectID: "/a", registered: now.addingTimeInterval(-500))
        fresh.lastSeen = now.addingTimeInterval(-10)
        var quiet = Agent(number: 2, projectID: "/b", registered: now.addingTimeInterval(-500))
        quiet.lastSeen = now.addingTimeInterval(-900)
        var gone = Agent(number: 3, projectID: "/c", registered: now.addingTimeInterval(-500))
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
        // Its agent has a question open, so the project waits with it.
        // Its agent has a question open, so the project wants you too. (T423: that is
        // the one state you can act on, so it beats everything but being gone.)
        #expect(d.projects[0].activity == .askingYou)
        // The current task is on the backlog, not next to the project's name. (T168)
        #expect(d.projects[0].doing == nil)
        #expect(d.projects[0].backlogCount == 1)
        // Its agent has said nothing for fifteen minutes: nothing is moving.
        #expect(d.projects[1].activity == .finished)
        #expect(d.projects[1].doing == nil)
        #expect(d.workingCount == 0)
        #expect(d.agents.map(\.agent.label) == ["A1", "A2"])
        #expect(d.agents[0].waitingOnYou)
        #expect(!d.agents[1].waitingOnYou)
    }

    /// Everything in an agent's name, and its one report, come off the status. The sidebar
    /// worked both out in a view body, once per row and again for the row's help. (T526.)
    @Test func aStatusCarriesEverythingInItsAgentsName() {
        let p = Project(name: "a", id: "/a")
        let agent = Agent(number: 1, projectID: "/a", registered: now)
        let other = Agent(number: 2, projectID: "/a", registered: now)
        var blocked = FactoryTask(projectID: p.id, title: "blocked", state: .blocked, rank: 1)
        blocked.agentID = agent.id
        var going = FactoryTask(projectID: p.id, title: "going", state: .inProgress, rank: 2)
        going.agentID = agent.id
        var finished = FactoryTask(projectID: p.id, title: "done", state: .succeeded, rank: 3)
        finished.agentID = agent.id
        var theirs = FactoryTask(projectID: p.id, title: "theirs", state: .inProgress, rank: 4)
        theirs.agentID = other.id
        var mine = Artifact(projectID: p.id, title: "A1", body: "on it", kind: .statusReport)
        mine.agentID = agent.id
        var elsewhere = Artifact(projectID: "/b", title: "A1", body: "somewhere else", kind: .statusReport)
        elsewhere.agentID = agent.id
        let d = Dashboard.make(
            snapshot: Snapshot(projects: [p], tasks: [blocked, going, finished, theirs],
                               artifacts: [mine, elsewhere], agents: [agent, other]),
            now: now)

        let first = d.agents[0]
        // Blocked first, finished left out, and somebody else's is not yours.
        #expect(first.held.map(\.title) == ["blocked", "going"])
        #expect(d.agents[1].held.map(\.title) == ["theirs"])
        // The report on the project it is on, not the one it left behind on another.
        #expect(first.report?.body == "on it")
        #expect(d.agents[1].report == nil)
        // The same answers the views used to work out for themselves.
        #expect(first.held == Backlog.alreadyYours(agent.id, in: [blocked, going, finished, theirs]))
        #expect(first.report == Artifacts.statusReport(by: agent.id, on: "/a", in: [mine, elsewhere]))
    }

    /// An agent the app starts knows its name before it registers. The number is taken
    /// off the factory's counter, so nothing about the agents still in the store can
    /// hand the same one out twice.
    @Test func anAgentCanBeReservedBeforeItRegisters() {
        let reserved = Agents.reserve(number: 5, projectID: "/p", now: now)
        #expect(reserved.number == 5)
        #expect(reserved.label == "A5")
        #expect(reserved.projectID == "/p")
        #expect(reserved.isRegistered)
        #expect(Agents.reserve(number: 1, projectID: nil, now: now).label == "A1")
    }

    /// The cards keep their places: agents read in the order they registered, whatever
    /// order they happen to speak in.
    @Test func agentsStayInTheOrderTheyRegistered() {
        var first = Agent(number: 1, projectID: nil, registered: now.addingTimeInterval(-300))
        first.lastSeen = now.addingTimeInterval(-120)          // spoke a while ago
        var second = Agent(number: 2, projectID: nil, registered: now.addingTimeInterval(-200))
        second.lastSeen = now                                   // spoke just now
        var third = Agent(number: 3, projectID: nil, registered: now.addingTimeInterval(-100))
        third.lastSeen = now.addingTimeInterval(-60)
        let d = Dashboard.make(snapshot: Snapshot(agents: [third, second, first]), now: now)
        #expect(d.agents.map(\.agent.label) == ["A1", "A2", "A3"])
        #expect(d.unassignedAgents.map(\.agent.label) == ["A1", "A2", "A3"])
        // All three spoke within the ten minutes and none has a question open, so the
        // group reads working. (T423.)
        #expect(d.unassignedActivity == .working)
        #expect(!d.unassignedIsEmpty)
    }

    /// A project reads the way its agents do: green working, orange waiting or blocked,
    /// grey for anything else.
    @Test func aProjectReadsTheWayItsAgentsDo() {
        let project = Project(name: "p", id: "/p")
        var agent = Agent(number: 1, projectID: "/p", registered: now.addingTimeInterval(-500))
        agent.lastSeen = now.addingTimeInterval(-10)
        var task = FactoryTask(projectID: "/p", title: "on it", state: .inProgress, rank: 0)
        task.agentID = agent.id
        agent.taskID = task.id

        func dot(_ tasks: [FactoryTask], _ escalations: [Escalation] = [], agent: Agent) -> Dashboard.ProjectActivity {
            Dashboard.make(snapshot: Snapshot(projects: [project], tasks: tasks, escalations: escalations, agents: [agent]), now: now)
                .projects[0].activity
        }

        #expect(dot([task], agent: agent) == .working)

        var blocked = task
        blocked.state = .blocked
        blocked.blockers = [.init(kind: .person, why: "the answer")]
        // Blocked on a person is you being asked; blocked on a task or a decision is not.
        #expect(dot([blocked], agent: agent) == .askingYou)

        // A question open is the agent waiting, and the project waits with it.
        let question = Escalation(projectID: "/p", question: "?", options: [.init(title: "a")], agentID: agent.id, raised: now)
        #expect(dot([task], [question], agent: agent) == .askingYou)
        // A project nobody is on says so, and draws no dot.
        let empty = Dashboard.make(snapshot: Snapshot(projects: [project]), now: now).projects[0]
        #expect(empty.activity == .finished && empty.isEmpty)

        var silent = agent
        silent.lastSeen = now.addingTimeInterval(-900)
        #expect(dot([task], agent: silent) == .finished)
        #expect(Dashboard.make(snapshot: Snapshot(projects: [project]), now: now).projects[0].activity == .finished)
    }

    @Test func aProjectOnHoldShowsItsNameAndNothingElse() {
        var held = Project(name: "held", id: "/held")
        held.onHold = true
        var agent = Agent(number: 1, projectID: held.id, registered: now)
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
        #expect(h.activity == .finished)
        #expect(h.doing == nil)
        #expect(h.inProgressCount == 0 && h.blockedCount == 0 && h.backlogCount == 0 && h.doneCount == 0)
        // Its question is still a question: the project says nothing about it, and the
        // dashboard's own list, which is what the Needs you strip, the banner, the phone
        // and the Lock Screen all read, still has it. (T507.)
        #expect(d.openEscalations.map(\.id) == [question.id])
        #expect(d.inProgress == 1)
        // The agent is still registered; it is the project that is quiet.
        #expect(d.agents.map(\.agent.label) == ["A1"])
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

    @Test func editingChangesOnlyPersonOwnedTaskDetails() {
        let day = Date(timeIntervalSince1970: 1_789_259_200)
        var task = FactoryTask(projectID: "/a", title: "before", state: .inProgress, rank: 1, note: "old")
        task.agentID = UUID()
        task.blockers = [.init(kind: .person, why: "the answer")]
        let edited = Backlog.edit(task, title: "  after  ", note: "  new note\n", at: day)
        #expect(edited.title == "after" && edited.note == "new note")
        #expect(edited.state == .inProgress && edited.agentID == task.agentID && edited.blockers == task.blockers)
        #expect(edited.updated == day)
        #expect(Backlog.edit(edited, title: " ", note: "ignored").title == "after")
        // Nothing to change means nothing changed, so the date does not move either.
        #expect(Backlog.edit(edited, title: "after", note: "new note") == edited)
    }

    /// The four states behind an agent's dot: working, blocked, waiting, idle.
    @Test func anAgentsDotSaysWorkingBlockedWaitingOrIdle() {
        let project = Project(name: "a", id: "/a")
        var agent = Agent(number: 1, projectID: project.id, registered: now.addingTimeInterval(-500))
        agent.lastSeen = now.addingTimeInterval(-10)
        var task = FactoryTask(projectID: project.id, title: "on it", state: .inProgress, rank: 0)
        task.agentID = agent.id
        agent.taskID = task.id

        func activity(_ agent: Agent, _ tasks: [FactoryTask], _ escalations: [Escalation] = []) -> Dashboard.AgentActivity {
            Dashboard.make(snapshot: Snapshot(projects: [project], tasks: tasks, escalations: escalations, agents: [agent]), now: now)
                .agents[0].activity
        }

        #expect(activity(agent, [task]) == .working)

        // A task blocked on a person is you being asked, and that beats working.
        var blocked = task
        blocked.state = .blocked
        blocked.blockers = [.init(kind: .person, why: "the answer")]
        #expect(activity(agent, [blocked]) == .askingYou)

        // Nothing in hand is not a state of its own any more: holding no task and having
        // nothing in flight is finished, which is what it is. A question open is you
        // being asked, whatever else it is doing.
        var empty = agent
        empty.taskID = nil
        #expect(activity(empty, []) == .working)
        let question = Escalation(projectID: project.id, question: "?", options: [.init(title: "x")], agentID: agent.id, raised: now)
        #expect(activity(agent, [task], [question]) == .askingYou)

        func status(_ agent: Agent, _ tasks: [FactoryTask], _ escalations: [Escalation] = []) -> Dashboard.AgentStatus {
            Dashboard.make(snapshot: Snapshot(projects: [project], tasks: tasks, escalations: escalations, agents: [agent]), now: now)
                .agents[0]
        }
        // Ten minutes without a word and no connection open: idle, task or no task.
        var quiet = agent
        quiet.lastSeen = now.addingTimeInterval(-700)
        #expect(activity(quiet, [task]) == .finished)
        // Blocked on a person still reads as wanting you, however quiet the agent is: the
        // thing to clear is yours and it does not stop being yours after ten minutes.
        #expect(activity(quiet, [blocked]) == .askingYou)

        // Its process has gone: stopped, and no nudge. The pid is one nobody holds.
        var dead = agent
        dead.pid = 0x7FFF_FFFE
        dead.pidStartedAt = now
        #expect(activity(dead, [task]) == .stopped)
    }

    /// A folder under home reads as "~/…"; anything else reads as it is.
    @Test func aFolderUnderHomeReadsWithATilde() {
        let home = "/Users/alex"
        #expect(Projects.shortPath("/Users/alex/SoftwareFactory", home: home) == "~/SoftwareFactory")
        #expect(Projects.shortPath("/Users/alex", home: home) == "~")
        #expect(Projects.shortPath("/Volumes/Work/App", home: home) == "/Volumes/Work/App")
        // A longer name that merely starts the same is not home.
        #expect(Projects.shortPath("/Users/alexander/App", home: home) == "/Users/alexander/App")
        #expect(Projects.shortPath("/Users/alex/App", home: "") == "/Users/alex/App")
    }

    /// Who holds a resource reads as the agent's name, the same name the cards show.
    @Test func whoHoldsAResourceReadsAsItsName() {
        let phone = Resource(name: "iPhone", slots: 1, maxLease: 7200)
        var holder = Agent(number: 12, projectID: nil, registered: now)
        holder.lastSeen = now
        let lease = Lease(resourceID: phone.id, agentID: holder.id, why: "a capture run", since: now, until: now.addingTimeInterval(600))
        let d = Dashboard.make(snapshot: Snapshot(agents: [holder], resources: [phone], leases: [lease]), now: now)
        #expect(d.resources[0].held.map(\.agentName) == ["A12"])
        #expect(d.resources[0].occupancy == "1 of 1")
        let empty = Dashboard.make(snapshot: Snapshot(resources: [phone]), now: now)
        #expect(empty.resources[0].occupancy == "0 of 1")
    }

    @Test func idleProjectWithNothingOnShowsNothing() {
        let d = Dashboard.make(snapshot: Snapshot(projects: [Project(name: "a", id: "/a")]), now: now)
        #expect(d.projects[0].activity == .finished)
        #expect(d.projects[0].doing == nil)
    }
}

@Suite struct BacklogReminderTests {
    private func task(_ title: String, _ number: Int, _ state: FactoryTask.State,
                      for agent: UUID?) -> FactoryTask {
        var t = FactoryTask(projectID: "/p", title: title, rank: 0)
        t.number = number
        t.state = state
        t.agentID = agent
        return t
    }

    @Test func anAgentWithEmptyHandsIsNotReminded() {
        let me = UUID()
        let someoneElse = task("theirs", 1, .inProgress, for: UUID())
        let free = task("nobody's", 2, .backlog, for: nil)
        #expect(Backlog.reminder(for: me, in: [someoneElse, free]) == nil)
    }

    @Test func oneTaskIsNamedWithItsTitle() {
        let me = UUID()
        let mine = task("Fix the bell", 509, .inProgress, for: me)
        let line = Backlog.reminder(for: me, in: [mine])
        #expect(line?.contains("T509") == true)
        #expect(line?.contains("Fix the bell") == true)
        #expect(line?.contains("inProgress") == true)
        #expect(line?.contains("Fix the bell. Finish") == true)
    }

    @Test func aTitleThatEndsInAFullStopDoesNotGiveTheLineTwo() {
        let me = UUID()
        let mine = task("Remind them in the reply.", 270, .inProgress, for: me)
        #expect(Backlog.reminder(for: me, in: [mine])?.contains("in the reply. Finish") == true)
    }

    @Test func severalAreListedByNumber() {
        let me = UUID()
        let tasks = [task("one", 1, .inProgress, for: me),
                     task("two", 2, .backlog, for: me),
                     task("three", 3, .blocked, for: me)]
        let line = Backlog.reminder(for: me, in: tasks)
        // The same order as the backlog itself: blocked first, then in progress.
        #expect(line?.contains("T3, T1 and T2") == true)
    }

    @Test func finishedAndDeletedWorkIsNotSomethingToBeRemindedOf() {
        let me = UUID()
        let done = task("finished", 1, .succeeded, for: me)
        let deleted = Backlog.remove(task("deleted", 2, .inProgress, for: me), why: "by Alex")
        #expect(Backlog.reminder(for: me, in: [done, deleted]) == nil)
    }
}

/// Put away: stopped, and off every list. (T415, Alex, 15 Sep 2026.)
@Suite struct ArchiveTests {
    private func agent(archived: Bool) -> Agent {
        var a = Agent(number: 7, projectID: "/p")
        if archived { a.archivedAt = .now }
        return a
    }

    @Test func anArchivedAgentIsNotOnTheFloorAndHoldsNoSlot() {
        let here = agent(archived: false)
        let away = agent(archived: true)
        #expect(Agents.onTheFloor([here, away]).map(\.id) == [here.id])
        #expect(!Agents.atCap([here, away, agent(archived: true)], cap: 2))
    }

    @Test func archivingIsOfferedOnceAndTakingItBackOutTheOtherWay() {
        #expect(Agents.mayArchive(agent(archived: false)))
        #expect(!Agents.mayArchive(agent(archived: true)))
        #expect(Agents.mayUnarchive(agent(archived: true)))
        #expect(!Agents.mayUnarchive(agent(archived: false)))
    }

    /// Off the floor, and still somewhere: the dashboard carries them so there is a place
    /// to take one back out from. A page nobody can reach is what T392 had to fix.
    @Test func theDashboardKeepsThemApartRatherThanLosingThem() {
        let here = agent(archived: false)
        let away = agent(archived: true)
        let dash = Dashboard.make(snapshot: Snapshot(projects: [Project(name: "P", id: "/p")],
                                                     agents: [here, away]))
        #expect(dash.agents.map(\.id) == [here.id])
        #expect(dash.archived.map(\.id) == [away.id])
        #expect(dash.agents(on: "/p").map(\.id) == [here.id])
    }

    /// A record written before there was anywhere to put an agent away reads as one on
    /// the floor, which is what it was.
    @Test func anOlderRecordReadsAsNotArchived() throws {
        let old = #"{"version":3,"id":"\#(UUID().uuidString)","title":"","bel":false,"note":"","wantsLaunch":false,"registered":0,"lastSeen":0,"isConnected":false,"runtime":"terminal"}"#
        let read = try JSONDecoder().decode(Agent.self, from: Data(old.utf8))
        #expect(!read.isArchived)
    }
}

/// Where a project sits in the sidebar. (T437, Alex, 15 Sep 2026.)
@Suite struct ProjectOrderTests {
    private let now = Date()

    @Test func somebodyOnItComesAboveNobodyOnIt() {
        let worked = Project(name: "Zebra", id: "/z")
        let bare = Project(name: "Apple", id: "/a")
        var agent = Agent(number: 1, projectID: "/z")
        agent.lastSeen = now
        let d = Dashboard.make(snapshot: Snapshot(projects: [bare, worked], agents: [agent]), now: now)
        #expect(d.projects.map(\.project.name) == ["Zebra", "Apple"])
    }

    @Test func onHoldSinksBelowBoth() {
        var held = Project(name: "Aardvark", id: "/h")
        held.onHold = true
        var busy = Agent(number: 1, projectID: "/h")
        busy.lastSeen = now
        let d = Dashboard.make(snapshot: Snapshot(projects: [held, Project(name: "Beta", id: "/b")],
                                                  agents: [busy]), now: now)
        #expect(d.projects.map(\.project.name) == ["Beta", "Aardvark"])
    }

    /// An agent that has stopped is not somebody on it: the work is not moving, so it sits
    /// below every project that has somebody on it.
    @Test func aStoppedAgentDoesNotCountAsSomebodyOnIt() {
        var dead = Agent(number: 1, projectID: "/z")
        dead.lastSeen = now
        dead.pid = 0x7FFF_FFFE
        dead.pidStartedAt = now
        var live = Agent(number: 2, projectID: "/a")
        live.lastSeen = now
        let d = Dashboard.make(snapshot: Snapshot(projects: [Project(name: "Zebra", id: "/z"),
                                                             Project(name: "Apple", id: "/a")],
                                                  agents: [dead, live]), now: now)
        #expect(d.projects.map(\.project.name) == ["Apple", "Zebra"])
    }

    /// And above every project that has nobody on it at all. A stopped agent is work that
    /// was going and is not, which is something to pick back up; a project with no agents
    /// has not been started. They used to be one band, sorted by name, so which came first
    /// was an accident of spelling. (T499, Alex, 15 Sep 2026.)
    @Test func aStoppedAgentStillComesAboveNoAgentAtAll() {
        var dead = Agent(number: 1, projectID: "/z")
        dead.lastSeen = now
        dead.pid = 0x7FFF_FFFE
        dead.pidStartedAt = now
        let d = Dashboard.make(snapshot: Snapshot(projects: [Project(name: "Zebra", id: "/z"),
                                                             Project(name: "Apple", id: "/a")],
                                                  agents: [dead]), now: now)
        #expect(d.projects.map(\.project.name) == ["Zebra", "Apple"])
    }

    /// The whole order in one go: working, then an agent there but idle, then a stopped
    /// one, then nobody, then on hold.
    ///
    /// Five rows and four bands, which is the point of T513. Working and Idle are the same
    /// band now, and Working still comes first because the sort falls through to the
    /// activity rank inside a band. The order did not change; what changed is that it is
    /// said once instead of twice. (T513, Alex, 15 Sep 2026.)
    @Test func theOrderInOneGo() {
        var working = Agent(number: 1, projectID: "/w")
        working.lastSeen = now
        working.isPrompting = true
        working.runtime = .acp
        // There, not gone, and not mid-turn: the daemon is holding it and says so.
        var idle = Agent(number: 2, projectID: "/i")
        idle.lastSeen = now
        idle.runtime = .acp
        idle.isPrompting = false
        var dead = Agent(number: 3, projectID: "/s")
        dead.lastSeen = now
        dead.pid = 0x7FFF_FFFE
        dead.pidStartedAt = now
        var held = Project(name: "Held", id: "/h")
        held.onHold = true
        var busy = Agent(number: 4, projectID: "/h")
        busy.lastSeen = now
        busy.isPrompting = true
        busy.runtime = .acp
        let d = Dashboard.make(snapshot: Snapshot(
            projects: [held, Project(name: "Nobody", id: "/n"), Project(name: "Stopped", id: "/s"),
                       Project(name: "Idle", id: "/i"), Project(name: "Working", id: "/w")],
            agents: [working, idle, dead, busy]), now: now)
        #expect(d.projects.map(\.project.name) == ["Working", "Idle", "Stopped", "Nobody", "Held"])
        // Four bands over five rows, and the two at the top share one.
        let bands = d.projects.map(Dashboard.band)
        #expect(bands == [0, 0, 1, 2, 3])
        #expect(Set(bands).count == 4)
    }

    /// The band that went. A project whose agent has finished and one whose agent is working
    /// are both projects with somebody on them, and the activity rank is what separates
    /// them: it already put working above finished, so saying it again as a band was one
    /// rule repeating another, which is a rule that can disagree with it. (T513.)
    @Test func anAgentThatHasFinishedIsStillSomebodyOnIt() {
        var finished = Agent(number: 1, projectID: "/f")
        finished.lastSeen = now
        finished.runtime = .acp
        finished.isPrompting = false
        var dead = Agent(number: 2, projectID: "/s")
        dead.lastSeen = now
        dead.pid = 0x7FFF_FFFE
        dead.pidStartedAt = now
        let d = Dashboard.make(snapshot: Snapshot(
            projects: [Project(name: "Stopped", id: "/s"), Project(name: "Finished", id: "/f")],
            agents: [finished, dead]), now: now)
        // Same band as a working one would be, and above the one whose agent has gone.
        #expect(d.projects.map(Dashboard.band) == [0, 1])
        #expect(d.projects.map(\.project.name) == ["Finished", "Stopped"])
    }
}

/// Finished is two things now, and both of them are finished. (T488, Alex, 15 Sep 2026.)
@Suite struct FinishedTwoWaysTests {
    @Test func aRecordWrittenBeforeTonightReadsAsSucceeded() throws {
        let old = #"{"version":2,"id":"\#(UUID().uuidString)","projectID":"/p","title":"An old one","state":"done","rank":1,"note":"","created":0,"updated":0}"#
        let read = try JSONDecoder().decode(FactoryTask.self, from: Data(old.utf8))
        #expect(read.state == .succeeded)
        #expect(read.state.isFinished)
    }

    /// Every agent and every script written before tonight says "done", and still works.
    @Test func doneIsStillAWordACallerMayUse() {
        #expect(FactoryTask.State.parse("done") == .succeeded)
        #expect(FactoryTask.State.parse("succeeded") == .succeeded)
        #expect(FactoryTask.State.parse("failed") == .failed)
        #expect(FactoryTask.State.parse("nonsense") == nil)
    }

    @Test func bothAreOffTheBacklogAndOutOfAnAgentsName() {
        let project = "/p"
        let me = UUID()
        func task(_ title: String, _ state: FactoryTask.State) -> FactoryTask {
            var t = FactoryTask(projectID: project, title: title, state: state, rank: 1)
            t.agentID = me
            return t
        }
        let all = [task("worked", .succeeded), task("did not", .failed), task("still on it", .inProgress)]
        #expect(Backlog.alreadyYours(me, in: all).map(\.title) == ["still on it"])
        // They sort to opposite ends of the list now. What worked goes to the foot, after
        // what is parked; what failed goes above the backlog, because it is the half of
        // finished that somebody still has to do something about. (T488, then T509.)
        let order = Backlog.blocks(all.sorted(by: Backlog.order)).map(\.state)
        #expect(order == [.failed, .inProgress, .succeeded])
    }
}
