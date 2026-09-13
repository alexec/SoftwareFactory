import Foundation

/// What an agent is told the moment it starts. One place, so the words are the same
/// wherever the person started it from: a project's page, the Agents page, or one task
/// on a backlog.
public enum LaunchPrompt {
    /// An agent that works a project's backlog, in whatever order the backlog is in.
    public static func project(_ project: Project, as name: String) -> String {
        "You are agent \"\(name)\", working on the project \"\(project.name)\". "
        + "Register yourself with the factory as agent_id \"\(name)\", then work through its backlog of tasks."
    }

    /// An agent started for one task. The task is already in its name, so it is told
    /// which one and asked to claim it rather than to read the backlog and choose.
    public static func task(_ task: FactoryTask, in project: Project, as name: String) -> String {
        let label = task.label.map { "\($0), " } ?? ""
        return "You are agent \"\(name)\", working on the project \"\(project.name)\". "
            + "Register yourself with the factory as agent_id \"\(name)\". "
            + "The task \(label)\"\(task.title)\" is waiting in your name. "
            + "Claim it, read its note, do it, and say when it is done."
    }

    /// An agent on no project: the person says what it is for.
    public static func free(_ prompt: String, as name: String) -> String {
        "You are agent \"\(name)\". Register yourself with the factory as agent_id \"\(name)\". \(prompt)"
    }
}
