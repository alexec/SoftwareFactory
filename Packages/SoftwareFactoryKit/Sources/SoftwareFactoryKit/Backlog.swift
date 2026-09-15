import Foundation

/// The rules for a project's backlog. Pure functions over arrays so a view never decides.
public enum Backlog {
    /// The tasks for one project, in the order they should be shown: blocked first (they
    /// need someone), then in progress, then the backlog by rank, then parked by rank, then
    /// done, newest first. (Alex, 12 September 2026: blocked above in progress.)
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
        case .blocked: 0
        case .inProgress: 1
        case .backlog: 2
        case .parked: 3
        case .done: 4
        }
    }

    /// What the project view shows: everything in progress, blocked and on the backlog,
    /// then at most `recentParked` parked and `recentDone` done, so a long-lived project's
    /// list does not fill with what is set aside or finished. (Alex, 12 September 2026:
    /// three done, ten parked.)
    public static func visible(for projectID: String, in all: [FactoryTask], recentDone: Int = 3, recentParked: Int = 10) -> [FactoryTask] {
        var doneShown = 0, parkedShown = 0
        return tasks(for: projectID, in: all).filter { task in
            switch task.state {
            case .done: doneShown += 1; return doneShown <= recentDone
            case .parked: parkedShown += 1; return parkedShown <= recentParked
            default: return true
            }
        }
    }

    /// The list, in blocks by state, in the order they are shown. Empty blocks are left out.
    public static func blocks(_ tasks: [FactoryTask]) -> [(state: FactoryTask.State, tasks: [FactoryTask])] {
        let order: [FactoryTask.State] = [.blocked, .inProgress, .backlog, .parked, .done]
        return order.compactMap { state in
            let group = tasks.filter { $0.state == state }
            return group.isEmpty ? nil : (state, group)
        }
    }

    /// The next short number, across every project: one more than the highest in use.
    /// The first task numbered at all gets 1 unless someone sets a higher one first.
    public static func nextNumber(in all: [FactoryTask]) -> Int {
        (all.compactMap(\.number).max() ?? 0) + 1
    }

    /// A task by its number, said as "T509", "t509" or "509".
    public static func task(numbered ref: String, in all: [FactoryTask]) -> FactoryTask? {
        var digits = Substring(ref.trimmingCharacters(in: .whitespaces))
        if digits.first?.lowercased() == "t" { digits = digits.dropFirst() }
        guard let n = Int(digits) else { return nil }
        return all.first { $0.number == n }
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
        /// Added straight to parked: seen and set aside without ever sitting on the backlog.
        case top, bottom, parked
    }

    public static func rank(for position: Position, projectID: String, in all: [FactoryTask]) -> Int {
        position == .top ? topRank(for: projectID, in: all) : nextRank(for: projectID, in: all)
    }

    /// The state a newly added task starts in: parked if asked for that, backlog otherwise.
    public static func state(for position: Position) -> FactoryTask.State {
        position == .parked ? .parked : .backlog
    }

    /// The top task nobody is on. A task the person put someone's name against is
    /// theirs: it comes first for that agent, and is passed over by everyone else.
    /// (Alex, 12 Sep 2026.)
    public static func next(for projectID: String, in all: [FactoryTask], agentID: UUID? = nil) -> FactoryTask? {
        let waiting = tasks(for: projectID, in: all).filter { $0.state == .backlog }
        if let agentID, let mine = waiting.first(where: { $0.agentID == agentID }) { return mine }
        return waiting.first { $0.agentID == nil }
    }

    /// Puts a task in one agent's name, or takes the name off with nil. The task stays
    /// where it is on the backlog; the agent claims it when it starts.
    public static func assign(_ task: FactoryTask, to agentID: UUID?, named name: String?, by who: String, at date: Date = .now) -> FactoryTask {
        guard task.agentID != agentID else { return task }
        var assigned = task
        assigned.agentID = agentID
        assigned.updated = date
        let line = agentID == nil ? "unassigned" : "assigned to \(name ?? "an agent")"
        return comment(on: assigned, line, by: who, at: date)
    }

    /// Moves the tasks of one project in `states` the way a list's `onMove` describes it,
    /// and returns every task whose rank changed so the caller can save just those. The
    /// backlog (with in progress alongside it, so a claimed task keeps its place) by
    /// default; pass `[.parked]` to reorder what is set aside instead.
    public static func move(
        in tasks: [FactoryTask], from source: IndexSet, to destination: Int,
        states: Set<FactoryTask.State> = [.backlog, .inProgress], at date: Date = .now
    ) -> [FactoryTask] {
        let open = tasks.filter { states.contains($0.state) }.sorted(by: order)
        // The same semantics as SwiftUI's onMove: the moved tasks land before the task
        // that was at `destination` in the unmoved list.
        let moving = source.map { open[$0] }
        var rest = open.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        return renumber(rest, at: date)
    }

    /// Puts one task directly above another, among `states`, and returns every task
    /// whose rank changed. The backlog (with in progress alongside it) by default; pass
    /// `[.parked]` to place within what is set aside instead.
    public static func place(
        _ task: FactoryTask, above other: FactoryTask, in tasks: [FactoryTask],
        states: Set<FactoryTask.State> = [.backlog, .inProgress], at date: Date = .now
    ) -> [FactoryTask] {
        guard task.id != other.id else { return [] }
        var open = tasks.filter { states.contains($0.state) && $0.id != task.id }.sorted(by: order)
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
        if state != .blocked { task.blockers = [] }
        return task
    }

    /// Adds a line to the task's note, signed and dated, so whoever reads it next knows
    /// who said it. Anything else about the task stays as it is.
    public static func comment(on task: FactoryTask, _ text: String, by who: String, at date: Date = .now) -> FactoryTask {
        var task = task
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return task }
        let day = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "en_GB")))
        let line = "\(who), \(day): \(text)"
        task.note = task.note.isEmpty ? line : task.note + "\n" + line
        task.updated = date
        return task
    }

    /// Changes the person-owned details of a task without disturbing its state or the
    /// agent work recorded on it. An empty title is not a task, so it leaves it alone.
    public static func edit(
        _ task: FactoryTask, title: String, note: String, work: FactoryTask.Work? = nil,
        at date: Date = .now
    ) -> FactoryTask {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return task }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let work = work ?? task.work
        guard task.title != title || task.note != note || task.work != work else { return task }
        var task = task
        task.title = title
        task.note = note
        task.work = work
        task.updated = date
        return task
    }

    /// Takes a task off the backlog without losing it: the record stays, with the reason.
    public static func remove(_ task: FactoryTask, why: String, at date: Date = .now) -> FactoryTask {
        var task = task
        task.removed = date
        task.updated = date
        let line = "removed" + (why.isEmpty ? "" : ": \(why)")
        task.note = task.note.isEmpty ? line : task.note + "\n" + line
        return task
    }

    /// Clears one blocker, named by its position or by words from its reason. The task
    /// leaves blocked only when none is left.
    public static func unblock(_ task: FactoryTask, matching text: String, at date: Date = .now) throws(UnblockError) -> FactoryTask {
        var task = task
        let index: Int
        if let n = Int(text), n >= 1, n <= task.blockers.count {
            index = n - 1
        } else {
            let hits = task.blockers.indices.filter { task.blockers[$0].why.localizedCaseInsensitiveContains(text) }
            guard hits.count == 1 else { throw hits.isEmpty ? .noMatch : .ambiguous }
            index = hits[0]
        }
        let gone = task.blockers.remove(at: index)
        task.updated = date
        let line = "cleared by hand: \(gone.why)"
        task.note = task.note.isEmpty ? line : task.note + "\n" + line
        if task.blockers.isEmpty { task = set(task, to: .backlog, at: date) }
        return task
    }

    public enum UnblockError: Error, Equatable, Sendable {
        case noMatch, ambiguous
    }

    /// Marks a task blocked on one more thing. The agent keeps its name on it, so the
    /// note still says who was on it when it clears. The same thing twice is once.
    public static func block(_ task: FactoryTask, on blocker: FactoryTask.Blocker, at date: Date = .now) -> FactoryTask {
        var task = task
        task.state = .blocked
        // A block on a person followed by a block on a decision is the same gate said
        // twice: the question is how the person is asked. The decision replaces the wait
        // on the person, so the row clears itself when the answer lands. (Brushwise and
        // Wall First leads, 12 Sep 2026.) A person block added after a decision is a
        // second, different wait and stays.
        if blocker.kind == .decision {
            task.blockers.removeAll { $0.kind == .person }
        }
        if !task.blockers.contains(where: { $0.kind == blocker.kind && $0.id == blocker.id && $0.why == blocker.why }) {
            task.blockers.append(blocker)
        }
        task.updated = date
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
