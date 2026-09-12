import Foundation
import Testing
@testable import ForemanKit

@Suite struct BacklogTests {
    let p = "/p"

    func item(_ title: String, rank: Int, state: WorkItem.State = .backlog, updated: TimeInterval = 0) -> WorkItem {
        var i = WorkItem(projectID: p, title: title, state: state, rank: rank, created: Date(timeIntervalSince1970: 0))
        i.updated = Date(timeIntervalSince1970: updated)
        return i
    }

    @Test func orderIsInProgressThenBacklogByRankThenDoneNewestFirst() {
        let all = [
            item("done old", rank: 0, state: .done, updated: 10),
            item("second", rank: 2),
            item("done new", rank: 1, state: .done, updated: 20),
            item("first", rank: 1),
            item("now", rank: 5, state: .inProgress),
            WorkItem(projectID: "/other", title: "elsewhere", rank: 0),
        ]
        #expect(Backlog.items(for: p, in: all).map(\.title) == ["now", "first", "second", "done new", "done old"])
    }

    @Test func nextRankFollowsTheProject() {
        let all = [item("a", rank: 4), WorkItem(projectID: "/other", title: "b", rank: 99)]
        #expect(Backlog.nextRank(for: p, in: all) == 5)
        #expect(Backlog.nextRank(for: "/new", in: all) == 0)
    }

    @Test func moveRenumbersOnlyWhatChanged() {
        let all = [item("a", rank: 0), item("b", rank: 1), item("c", rank: 2), item("done", rank: 3, state: .done)]
        let changed = Backlog.move(in: all, from: IndexSet(integer: 2), to: 0)
        #expect(changed.map(\.title) == ["c", "a", "b"])
        #expect(changed.map(\.rank) == [0, 1, 2])
    }

    @Test func startingRecordsTheAgentAndBacklogForgetsIt() {
        let started = Backlog.set(item("a", rank: 0), to: .inProgress, agent: "agent-2")
        #expect(started.state == .inProgress)
        #expect(started.agent == "agent-2")
        let back = Backlog.set(started, to: .backlog)
        #expect(back.agent == nil)
    }

    @Test func currentIsTheNewestInProgressItem() {
        let all = [item("older", rank: 0, state: .inProgress, updated: 1), item("newer", rank: 1, state: .inProgress, updated: 2)]
        #expect(Backlog.current(for: p, in: all)?.title == "newer")
        #expect(Backlog.current(for: "/none", in: all) == nil)
    }
}

@Suite struct DashboardTests {
    let now = Date(timeIntervalSince1970: 10_000)

    @Test func countsAndActivity() {
        let a = Project(path: "/a")
        let snap = Snapshot(
            projects: [a],
            items: [
                WorkItem(projectID: a.id, title: "on it", state: .inProgress, rank: 0),
                WorkItem(projectID: a.id, title: "later", rank: 1),
                WorkItem(projectID: "/b", title: "also on it", state: .inProgress, rank: 0),
            ],
            escalations: [Escalation(projectID: a.id, question: "?", options: [.init(title: "x"), .init(title: "y")])]
        )
        let sessions = [
            AgentSession(id: "1", cwd: "/a", lastActivity: now.addingTimeInterval(-10), lastPrompt: "fix", isLive: true),
            AgentSession(id: "2", cwd: "/b", lastActivity: now.addingTimeInterval(-600), lastPrompt: "hello", isLive: true),
            AgentSession(id: "3", cwd: "/c", lastActivity: now.addingTimeInterval(-5), isLive: false),
            AgentSession(id: "4", cwd: "/x/scratch-workspaces/y", lastActivity: now, isLive: true),
        ]
        let d = Dashboard.make(snapshot: snap, sessions: sessions, now: now)

        #expect(d.inProgress == 2)
        #expect(d.openEscalations.count == 1)
        #expect(d.projects.map(\.project.name) == ["a", "b"])   // /c ended, scratch skipped
        #expect(d.projects[0].activity == .working)
        #expect(d.projects[0].doing == "on it")
        #expect(d.projects[0].backlogCount == 1)
        #expect(d.projects[0].openEscalations == 1)
        #expect(d.projects[1].activity == .waiting)
        #expect(d.projects[1].doing == "also on it")
        #expect(d.workingCount == 1)
        #expect(d.waitingCount == 1)
    }

    @Test func idleProjectShowsNoPromptAsDoing() {
        let snap = Snapshot(projects: [Project(path: "/a")])
        let sessions = [AgentSession(id: "1", cwd: "/a", lastActivity: now, lastPrompt: "old", isLive: false)]
        let d = Dashboard.make(snapshot: snap, sessions: sessions, now: now)
        #expect(d.projects[0].activity == .idle)
        #expect(d.projects[0].doing == nil)
    }

    @Test func workingProjectFallsBackToTheLastPrompt() {
        let snap = Snapshot(projects: [Project(path: "/a")])
        let sessions = [AgentSession(id: "1", cwd: "/a", lastActivity: now, lastPrompt: "make it blue", isLive: true)]
        let d = Dashboard.make(snapshot: snap, sessions: sessions, now: now)
        #expect(d.projects[0].doing == "make it blue")
    }
}
