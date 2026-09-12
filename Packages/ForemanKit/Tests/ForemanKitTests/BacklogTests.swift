import Foundation
import Testing
@testable import ForemanKit

@Suite struct BacklogTests {
    let p = "/p"

    func task(_ title: String, rank: Int, state: FactoryTask.State = .backlog, updated: TimeInterval = 0) -> FactoryTask {
        var t = FactoryTask(projectID: p, title: title, state: state, rank: rank, created: Date(timeIntervalSince1970: 0))
        t.updated = Date(timeIntervalSince1970: updated)
        return t
    }

    @Test func orderIsInProgressThenBacklogByRankThenDoneNewestFirst() {
        let all = [
            task("done old", rank: 0, state: .done, updated: 10),
            task("second", rank: 2),
            task("done new", rank: 1, state: .done, updated: 20),
            task("first", rank: 1),
            task("now", rank: 5, state: .inProgress),
            FactoryTask(projectID: "/other", title: "elsewhere", rank: 0),
        ]
        #expect(Backlog.tasks(for: p, in: all).map(\.title) == ["now", "first", "second", "done new", "done old"])
        #expect(Backlog.next(for: p, in: all)?.title == "first")
    }

    @Test func nextRankFollowsTheProject() {
        let all = [task("a", rank: 4), FactoryTask(projectID: "/other", title: "b", rank: 99)]
        #expect(Backlog.nextRank(for: p, in: all) == 5)
        #expect(Backlog.nextRank(for: "/new", in: all) == 0)
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
        let a = Project(path: "/a")
        var fresh = Agent(name: "one", projectID: "/a", registered: now.addingTimeInterval(-500))
        fresh.lastSeen = now.addingTimeInterval(-10)
        var quiet = Agent(name: "two", projectID: "/b", registered: now.addingTimeInterval(-500))
        quiet.lastSeen = now.addingTimeInterval(-600)
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

    @Test func idleProjectWithNothingOnShowsNothing() {
        let d = Dashboard.make(snapshot: Snapshot(projects: [Project(path: "/a")]), now: now)
        #expect(d.projects[0].activity == .idle)
        #expect(d.projects[0].doing == nil)
    }
}
