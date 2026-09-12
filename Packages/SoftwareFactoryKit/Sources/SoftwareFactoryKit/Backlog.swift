import Foundation

/// The rules for a project's backlog. Pure functions over arrays so a view never decides.
public enum Backlog {
    /// The tasks for one project, in the order they should be shown: in progress first,
    /// then the backlog by rank, then parked by rank, then done, newest first.
    public static func tasks(for projectID: String, in all: [FactoryTask]) -> [FactoryTask] {
        all.filter { $0.projectID == projectID }.sorted(by: order)
    }

    public static func order(_ a: FactoryTask, _ b: FactoryTask) -> Bool {
        if a.state != b.state { return stateOrder(a.state) < stateOrder(b.state) }
        if a.state == .done { return a.updated > b.updated }
        if a.rank != b.rank { return a.rank < b.rank }
        return a.created < b.created
    }

    private static func stateOrder(_ s: FactoryTask.State) -> Int {
        switch s {
        case .inProgress: 0
        case .backlog: 1
        case .parked: 2
        case .done: 3
        }
    }

    /// What the project view shows: everything open, then only the newest few done, so a
    /// long-lived project's list does not fill with what is finished.
    public static func visible(for projectID: String, in all: [FactoryTask], recentDone: Int = 5) -> [FactoryTask] {
        var shown = 0
        return tasks(for: projectID, in: all).filter { task in
            guard task.state == .done else { return true }
            shown += 1
            return shown <= recentDone
        }
    }

    /// The rank a new task gets: after everything already on that project.
    public static func nextRank(for projectID: String, in all: [FactoryTask]) -> Int {
        (all.filter { $0.projectID == projectID }.map(\.rank).max() ?? -1) + 1
    }

    /// The rank that puts a new task first. Ranks may go negative; only their order matters.
    public static func topRank(for projectID: String, in all: [FactoryTask]) -> Int {
        (all.filter { $0.projectID == projectID && $0.state != .done }.map(\.rank).min() ?? 1) - 1
    }

    public enum Position: String, Codable, Sendable {
        case top, bottom
    }

    public static func rank(for position: Position, projectID: String, in all: [FactoryTask]) -> Int {
        position == .top ? topRank(for: projectID, in: all) : nextRank(for: projectID, in: all)
    }

    /// The top task nobody is on.
    public static func next(for projectID: String, in all: [FactoryTask]) -> FactoryTask? {
        tasks(for: projectID, in: all).first { $0.state == .backlog }
    }

    /// Moves the open tasks of one project the way a list's `onMove` describes it, and
    /// returns every task whose rank changed so the caller can save just those.
    public static func move(
        in tasks: [FactoryTask], from source: IndexSet, to destination: Int, at date: Date = .now
    ) -> [FactoryTask] {
        let open = tasks.filter { $0.state != .done && $0.state != .parked }.sorted(by: order)
        // The same semantics as SwiftUI's onMove: the moved tasks land before the task
        // that was at `destination` in the unmoved list.
        let moving = source.map { open[$0] }
        var rest = open.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        return renumber(rest, at: date)
    }

    /// Puts one task directly above another and returns every task whose rank changed.
    public static func place(
        _ task: FactoryTask, above other: FactoryTask, in tasks: [FactoryTask], at date: Date = .now
    ) -> [FactoryTask] {
        guard task.id != other.id else { return [] }
        var open = tasks.filter { $0.state != .done && $0.state != .parked && $0.id != task.id }.sorted(by: order)
        let at = open.firstIndex { $0.id == other.id } ?? open.count
        open.insert(task, at: at)
        return renumber(open, at: date)
    }

    private static func renumber(_ ordered: [FactoryTask], at date: Date) -> [FactoryTask] {
        var changed: [FactoryTask] = []
        for (rank, var task) in ordered.enumerated() where task.rank != rank {
            task.rank = rank
            task.updated = date
            changed.append(task)
        }
        return changed
    }

    /// Changes a task's state, stamping who and when.
    public static func set(
        _ task: FactoryTask, to state: FactoryTask.State, agentID: UUID? = nil, at date: Date = .now
    ) -> FactoryTask {
        var task = task
        task.state = state
        task.updated = date
        if let agentID { task.agentID = agentID }
        if state == .backlog || state == .parked { task.agentID = nil }
        return task
    }

    /// Who may set which state. The person parks and unparks; only an agent, which is
    /// doing the work, says a task is in progress or done. (Alex, 12 September 2026.)
    public static let personMaySet: [FactoryTask.State] = [.backlog, .parked]

    /// The one task a project is on right now: the in-progress task that changed most recently.
    public static func current(for projectID: String, in all: [FactoryTask]) -> FactoryTask? {
        all.filter { $0.projectID == projectID && $0.state == .inProgress }
            .max { $0.updated < $1.updated }
    }
}
