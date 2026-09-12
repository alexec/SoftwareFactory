import Foundation

/// Records for a Debug build to look at before any agent has written one.
public enum SampleData {
    public static func snapshot(now: Date = .now) -> Snapshot {
        let where_ = Project(path: "/Users/alexcollins/Where", added: now.addingTimeInterval(-86400 * 3))
        let packed = Project(path: "/Users/alexcollins/Packed", added: now.addingTimeInterval(-86400 * 2))

        let items = [
            WorkItem(projectID: where_.id, title: "Rooms run together when dictated", kind: .bug,
                     state: .inProgress, rank: 0, agent: "agent-1", created: now.addingTimeInterval(-7200)),
            WorkItem(projectID: where_.id, title: "Search across every box", kind: .feature, rank: 1,
                     created: now.addingTimeInterval(-6000)),
            WorkItem(projectID: where_.id, title: "Regenerate the icon from the script", kind: .chore, rank: 2,
                     created: now.addingTimeInterval(-5000)),
            WorkItem(projectID: packed.id, title: "Weather for the trip's first day", kind: .feature, rank: 0,
                     created: now.addingTimeInterval(-4000)),
            WorkItem(projectID: packed.id, title: "Ticking a bag item skips one", kind: .bug, rank: 1,
                     created: now.addingTimeInterval(-3000)),
        ]

        let escalation = Escalation(
            projectID: packed.id,
            question: "Which weather source should Packed use?",
            context: "WeatherKit needs a paid capability and a key; Open-Meteo is free with no key but not from Apple.",
            options: [
                .init(title: "WeatherKit", detail: "Apple's own. Costs the capability; matches the Weather app.", recommended: true),
                .init(title: "Open-Meteo", detail: "Free, no key, one HTTP call. Attribution line in Settings."),
                .init(title: "No weather", detail: "Drop the feature for now."),
            ],
            raisedBy: "Packed lead",
            raised: now.addingTimeInterval(-1800)
        )

        return Snapshot(projects: [where_, packed], items: items, escalations: [escalation])
    }

    public static func write(to store: FileStore, now: Date = .now) throws {
        let s = snapshot(now: now)
        for p in s.projects { try store.save(p) }
        for i in s.items { try store.save(i) }
        for e in s.escalations { try store.save(e) }
    }
}
