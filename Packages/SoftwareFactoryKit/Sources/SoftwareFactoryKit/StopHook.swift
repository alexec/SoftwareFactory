import Foundation

/// Claude Code's own "Stop" hook: when a session is about to go idle, this decides
/// whether to hand it the next thing to do instead of letting it stop — the top task on
/// its project's backlog, offered once per agent, the same way a note or a nudge is
/// handed over once. (Alex, 12 Sep 2026: push a waiting task to an idle agent without
/// waiting for its next MCP call, using Claude Code's documented Stop hook rather than
/// any private API or on-screen automation.)
public enum StopHook {
    /// `sessionID` is matched against each agent's `url` (a
    /// claude://code/continue?session=<id> link), the only place a session id is
    /// recorded today. `stopHookActive` is Claude Code's own re-entrancy flag: true
    /// means this stop is already the result of an earlier block, so nothing more is
    /// offered this time.
    public static func check(sessionID: String, stopHookActive: Bool, in snapshot: Snapshot) -> (agent: Agent, task: FactoryTask)? {
        guard !stopHookActive, !sessionID.isEmpty else { return nil }
        guard let agent = snapshot.agents.first(where: { $0.isOnTheFloor && ($0.url ?? "").contains(sessionID) })
        else { return nil }
        guard let projectID = agent.projectID,
              let project = snapshot.projects.first(where: { $0.id == projectID }), !project.onHold
        else { return nil }
        guard let task = Backlog.next(for: projectID, in: snapshot.tasks), !agent.announcedTasks.contains(task.id)
        else { return nil }
        return (agent, task)
    }

    /// Marks the task announced to this agent, so it is offered once, and returns the
    /// words for the hook to hand back as the block reason.
    public static func announce(_ task: FactoryTask, to agent: Agent) -> (agent: Agent, reason: String) {
        var a = agent
        a.announcedTasks = Array((a.announcedTasks + [task.id]).suffix(50))
        let label = task.label.map { "\($0) " } ?? ""
        let reason = "You have a new task on your backlog which you may be able to start on when you've finished any current work you're doing: \(label)\(task.title)"
        return (a, reason)
    }
}
