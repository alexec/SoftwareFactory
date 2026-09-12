import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct StopHookTests {
    let p = Project(name: "P")

    func agent(url: String) -> Agent {
        var a = Agent(name: "a", projectID: p.id)
        a.provider = "claude-code"
        a.url = url
        return a
    }

    func snapshot(_ agent: Agent, _ tasks: [FactoryTask] = [], project: Project? = nil) -> Snapshot {
        Snapshot(projects: [project ?? p], tasks: tasks, agents: [agent])
    }

    @Test func offersTheTopOfTheBacklogOnceBySessionID() throws {
        let a = agent(url: "claude://code/continue?session=abc123")
        let t = FactoryTask(projectID: p.id, title: "Fix the thing", rank: 0)
        let snap = snapshot(a, [t])

        let hit = try #require(StopHook.check(sessionID: "abc123", stopHookActive: false, in: snap))
        #expect(hit.agent.id == a.id)
        #expect(hit.task.id == t.id)

        let (announced, reason) = StopHook.announce(hit.task, to: hit.agent)
        #expect(announced.announcedTasks == [t.id])
        #expect(reason.contains("Fix the thing"))
        #expect(reason.contains("may be able to start on when you've finished"))

        // Once announced, the same session hears nothing more about it.
        let again = snapshot(announced, [t])
        #expect(StopHook.check(sessionID: "abc123", stopHookActive: false, in: again) == nil)
    }

    @Test func nothingForAWrongSessionOrAnAlreadyReenteredStop() throws {
        let a = agent(url: "claude://code/continue?session=abc123")
        let t = FactoryTask(projectID: p.id, title: "Fix the thing", rank: 0)
        let snap = snapshot(a, [t])

        #expect(StopHook.check(sessionID: "someone-else", stopHookActive: false, in: snap) == nil)
        #expect(StopHook.check(sessionID: "abc123", stopHookActive: true, in: snap) == nil)
        #expect(StopHook.check(sessionID: "", stopHookActive: false, in: snap) == nil)
    }

    @Test func nothingWhileOnHoldOrWithNoTask() throws {
        let a = agent(url: "claude://code/continue?session=abc123")
        var onHold = p
        onHold.onHold = true
        #expect(StopHook.check(sessionID: "abc123", stopHookActive: false, in: snapshot(a, [], project: onHold)) == nil)
        #expect(StopHook.check(sessionID: "abc123", stopHookActive: false, in: snapshot(a, [])) == nil)
    }
}
