import Foundation

/// Records for a Debug build to look at before any agent has written one.
public enum SampleData {
    public static func snapshot(now: Date = .now) -> Snapshot {
        let where_ = Project(name: "Where", added: now.addingTimeInterval(-86400 * 3))
        let packed = Project(name: "Packed", added: now.addingTimeInterval(-86400 * 2))

        var agent1 = Agent(name: "agent-1", projectID: where_.id, registered: now.addingTimeInterval(-3000))
        agent1.lastSeen = now.addingTimeInterval(-20)
        agent1.note = "second attempt at splitting on pauses; testing on the simulator"
        var packedLead = Agent(name: "packed-lead", projectID: packed.id, registered: now.addingTimeInterval(-6000))
        packedLead.lastSeen = now.addingTimeInterval(-1700)

        var rooms = FactoryTask(projectID: where_.id, title: "Rooms run together when dictated", kind: .bug,
                                state: .inProgress, rank: 0, agentID: agent1.id, created: now.addingTimeInterval(-7200))
        rooms.updated = now.addingTimeInterval(-2500)
        agent1.taskID = rooms.id

        let tasks = [
            rooms,
            FactoryTask(projectID: where_.id, title: "Search across every box", kind: .feature, rank: 1,
                        created: now.addingTimeInterval(-6000)),
            FactoryTask(projectID: where_.id, title: "Regenerate the icon from the script", kind: .chore, rank: 2,
                        created: now.addingTimeInterval(-5000)),
            FactoryTask(projectID: packed.id, title: "Weather for the trip's first day", kind: .feature, rank: 0,
                        created: now.addingTimeInterval(-4000)),
            FactoryTask(projectID: packed.id, title: "Ticking a bag item skips one", kind: .bug, rank: 1,
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
            agentID: packedLead.id,
            raisedBy: "packed-lead",
            raised: now.addingTimeInterval(-1800)
        )

        return Snapshot(projects: [where_, packed], tasks: tasks, escalations: [escalation], agents: [agent1, packedLead])
    }

    public static func write(to store: FileStore, now: Date = .now) throws {
        let s = snapshot(now: now)
        for p in s.projects { try store.save(p) }
        for t in s.tasks { try store.save(t) }
        for e in s.escalations { try store.save(e) }
        for a in s.agents { try store.save(a) }
    }
}
