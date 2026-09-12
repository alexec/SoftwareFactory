import Foundation

/// The rules for a project's backlog. Pure functions over arrays so a view never decides.
public enum Backlog {
    /// The items for one project, in the order they should be shown: in progress first,
    /// then the backlog by rank, then done, newest first.
    public static func items(for projectID: String, in all: [WorkItem]) -> [WorkItem] {
        all.filter { $0.projectID == projectID }.sorted(by: order)
    }

    public static func order(_ a: WorkItem, _ b: WorkItem) -> Bool {
        if a.state != b.state { return stateOrder(a.state) < stateOrder(b.state) }
        if a.state == .done { return a.updated > b.updated }
        if a.rank != b.rank { return a.rank < b.rank }
        return a.created < b.created
    }

    private static func stateOrder(_ s: WorkItem.State) -> Int {
        switch s {
        case .inProgress: 0
        case .backlog: 1
        case .done: 2
        }
    }

    /// The rank a new item gets: after everything already on that project.
    public static func nextRank(for projectID: String, in all: [WorkItem]) -> Int {
        (all.filter { $0.projectID == projectID }.map(\.rank).max() ?? -1) + 1
    }

    /// Moves the open items of one project the way a list's `onMove` describes it, and
    /// returns every item whose rank changed so the caller can save just those.
    public static func move(
        in items: [WorkItem], from source: IndexSet, to destination: Int, at date: Date = .now
    ) -> [WorkItem] {
        let open = items.filter { $0.state != .done }.sorted(by: order)
        // The same semantics as SwiftUI's onMove: the moved items land before the item
        // that was at `destination` in the unmoved list.
        let moving = source.map { open[$0] }
        var rest = open.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        var changed: [WorkItem] = []
        for (rank, var item) in rest.enumerated() where item.rank != rank {
            item.rank = rank
            item.updated = date
            changed.append(item)
        }
        return changed
    }

    /// Changes an item's state, stamping who and when. Starting an item puts it at the top
    /// of the backlog order so it reads as the current one.
    public static func set(
        _ item: WorkItem, to state: WorkItem.State, agent: String? = nil, at date: Date = .now
    ) -> WorkItem {
        var item = item
        item.state = state
        item.updated = date
        if let agent { item.agent = agent }
        if state == .backlog { item.agent = nil }
        return item
    }

    /// The one item a project is on right now: the in-progress item that changed most
    /// recently, when there is one.
    public static func current(for projectID: String, in all: [WorkItem]) -> WorkItem? {
        all.filter { $0.projectID == projectID && $0.state == .inProgress }
            .max { $0.updated < $1.updated }
    }
}
