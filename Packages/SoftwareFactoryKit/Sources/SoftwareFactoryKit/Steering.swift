import Foundation

/// Notes from the person to whoever works on a project. A note waits on the project
/// and goes out on the agent's next call about that project, then it is gone: said
/// once, to one agent, like a word over the shoulder.
public enum Steering {
    /// Adds a note. Empty words add nothing.
    public static func note(_ text: String, on project: Project, by: String, at date: Date = .now) -> Project {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return project }
        var p = project
        p.notes.append(.init(text: text, by: by, at: date))
        return p
    }

    /// Takes a note back before any agent has seen it.
    public static func withdraw(_ id: UUID, from project: Project) -> Project {
        var p = project
        p.notes.removeAll { $0.id == id }
        return p
    }

    /// The words to append to a reply, and the project with those notes gone. Nothing
    /// to say gives nil and the project untouched.
    public static func handOver(_ project: Project) -> (text: String, project: Project)? {
        guard !project.notes.isEmpty else { return nil }
        let lines = project.notes.map { "NOTE FROM \($0.by.uppercased()): \($0.text)" }
        var p = project
        p.sentNoteIDs = Array((p.sentNoteIDs + p.notes.map(\.id)).suffix(50))
        p.notes = []
        return ("\n" + lines.joined(separator: "\n"), p)
    }

    /// Notes written on another device: on the copy from iCloud, not here, and not
    /// already handed over from here.
    public static func notesToAdopt(local: Project, cloud: Project) -> Project {
        let have = Set(local.notes.map(\.id) + local.sentNoteIDs)
        let fresh = cloud.notes.filter { !have.contains($0.id) }
        guard !fresh.isEmpty else { return local }
        var p = local
        p.notes += fresh
        return p
    }
}
