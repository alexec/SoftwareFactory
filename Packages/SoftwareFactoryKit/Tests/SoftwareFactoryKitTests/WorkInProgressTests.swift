import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct WorkInProgressTests {
    private func snapshot() -> (Snapshot, Project, Agent) {
        let project = Project(name: "Underway")
        var agent = Agent(projectID: project.id)
        agent.number = 7
        return (Snapshot(projects: [project], agents: [agent]), project, agent)
    }

    private func task(_ title: String, in project: Project, state: FactoryTask.State,
                      agent: Agent? = nil, updated: Date = .now) -> FactoryTask {
        var t = FactoryTask(projectID: project.id, title: title, rank: 0)
        t.state = state
        t.agentID = agent?.id
        t.updated = updated
        return t
    }

    @Test func onlyWhatIsUnderwayIsShown() {
        var (snap, project, agent) = snapshot()
        snap.tasks = [
            task("on it", in: project, state: .inProgress, agent: agent),
            task("waiting", in: project, state: .backlog),
            task("finished", in: project, state: .done, agent: agent),
            task("set aside", in: project, state: .parked),
        ]
        let rows = WorkInProgress.rows(in: snap)
        #expect(rows.map(\.task.title) == ["on it"])
        #expect(rows.first?.agentLabel == "A7")
        #expect(rows.first?.projectName == "Underway")
        #expect(rows.first?.nobodyOnIt == false)
    }

    @Test func theOnesNobodyIsOnComeFirstThenTheLongestRunning() {
        var (snap, project, agent) = snapshot()
        let old = Date(timeIntervalSince1970: 1_000)
        snap.tasks = [
            task("newest", in: project, state: .inProgress, agent: agent, updated: old.addingTimeInterval(300)),
            task("oldest", in: project, state: .inProgress, agent: agent, updated: old),
            task("abandoned", in: project, state: .inProgress, updated: old.addingTimeInterval(600)),
        ]
        #expect(WorkInProgress.rows(in: snap).map(\.task.title) == ["abandoned", "oldest", "newest"])
        #expect(WorkInProgress.orphaned(in: snap) == 1)
    }

    @Test func aRemovedTaskOrProjectIsNotUnderway() {
        var (snap, project, agent) = snapshot()
        let removedTask = Backlog.remove(task("deleted", in: project, state: .inProgress, agent: agent), why: "by Alex")
        var goneProject = Project(name: "Gone")
        goneProject.removed = .now
        var onGone = FactoryTask(projectID: goneProject.id, title: "on a removed project", rank: 0)
        onGone.state = .inProgress
        snap.projects.append(goneProject)
        snap.tasks = [removedTask, onGone]
        #expect(WorkInProgress.rows(in: snap).isEmpty)
    }
}
