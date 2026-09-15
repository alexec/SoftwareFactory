import Foundation

/// What an agent is told the moment it starts. One place, so the words are the same
/// wherever the person started it from: a project's page, the Agents page, or one task
/// on a backlog.
///
/// The session goes in the words rather than in the environment, and that is the whole
/// point of it. An environment variable is lost the moment a conversation is resumed:
/// the resumed process is started by something else and inherits none of it. The prompt
/// is part of the conversation, so an agent picked back up next week still knows which
/// session it is and can carry on being the same agent. (Alex, 13 Sep 2026.)
public enum LaunchPrompt {
    /// The line every agent starts with: who it is, and the session it says on every
    /// call it makes.
    static func youAre(_ name: String, _ session: UUID) -> String {
        "You are agent \"\(name)\". Your session_id is \(session.uuidString), and every "
        + "factory tool takes it: it is how the factory knows you. There is nothing to "
        + "register and nothing to say goodbye to; the factory already has you. Keep it."
    }

    /// An agent that works a project's backlog, in whatever order the backlog is in.
    public static func project(_ project: Project, as name: String, session: UUID) -> String {
        youAre(name, session)
        + " You are working on the project \"\(project.name)\". Work through its backlog"
        + " of tasks."
    }

    /// An agent started for one task. The task is already in its name, so it is told
    /// which one and asked to claim it rather than to read the backlog and choose.
    public static func task(_ task: FactoryTask, in project: Project, as name: String, session: UUID) -> String {
        let label = task.label.map { "\($0), " } ?? ""
        return youAre(name, session)
            + " You are working on the project \"\(project.name)\". The task"
            + " \(label)\"\(task.title)\" is waiting in your name."
            + " Claim it, read its note. \(task.work.instruction)"
    }

    /// An agent on no project: the person says what it is for.
    public static func free(_ prompt: String, as name: String, session: UUID) -> String {
        youAre(name, session) + " \(prompt)"
    }

    /// A poke for an agent that has finished and is sitting waiting. The words are written
    /// down as a message and typed into its terminal. (T171, 13 Sep 2026.)
    public static let nudge =
        "There is work waiting. Look at the backlog and take the next task nobody is on."
}
