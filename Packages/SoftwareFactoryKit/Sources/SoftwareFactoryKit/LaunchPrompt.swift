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

    /// The work half of the words, without the line that says who the agent is. This is
    /// what the person sees and may edit before they launch: the factory writes the name
    /// and the session in front of whatever they type, because those are not theirs to
    /// change. (T260.)
    public static func projectWork(_ project: Project) -> String {
        "You are working on the project \"\(project.name)\". Work through its backlog of tasks."
    }

    /// The same, for an agent started on one task.
    public static func taskWork(_ task: FactoryTask, in project: Project) -> String {
        let label = task.label.map { "\($0), " } ?? ""
        return "You are working on the project \"\(project.name)\". The task"
            + " \(label)\"\(task.title)\" is waiting in your name."
            + " Claim it, read its note. \(task.work.instruction)"
    }

    /// An agent that works a project's backlog, in whatever order the backlog is in.
    public static func project(_ project: Project, as name: String, session: UUID) -> String {
        free(projectWork(project), as: name, session: session)
    }

    /// An agent started for one task. The task is already in its name, so it is told
    /// which one and asked to claim it rather than to read the backlog and choose.
    public static func task(_ task: FactoryTask, in project: Project, as name: String, session: UUID) -> String {
        free(taskWork(task, in: project), as: name, session: session)
    }

    /// Whatever the person wants said, with the line that says who the agent is in
    /// front of it: an agent on no project, or one launched with the words edited.
    public static func free(_ prompt: String, as name: String, session: UUID) -> String {
        youAre(name, session) + " \(prompt)"
    }

    /// A poke for an agent that has finished and is sitting waiting. The words are written
    /// down as a message and typed into its terminal. (T171, 13 Sep 2026.)
    public static let nudge =
        "There is work waiting. Look at the backlog and take the next task nobody is on."

    /// What the factory asks an agent that has not said how its work is going for an
    /// hour. It goes in as a message like any other, so it is typed into the terminal
    /// and the agent answers by filing its status report. (T262.)
    ///
    /// The ask names what to put in it, because "how is it going" gets an essay from one
    /// agent and a shrug from the next. Four things: what is finished, what you decided,
    /// what you are waiting on Alex for, and where your questions stand. The last one is
    /// there because an agent that raised a question two hours ago and never looked at
    /// the answer is stuck without knowing it. (T274, Alex, 15 Sep 2026.)
    public static func statusReport(on project: Project) -> String {
        "Please provide a status report on your recent work on project \"\(project.name)\"."
            + " Keep it short: what you have finished since your last report, what you decided,"
            + " and anything you are waiting on Alex for."
            + " Check where your questions stand while you are there (escalation_list), and raise"
            + " any new ones you need answered."
            + " File it with artifact_add, kind \"status report\", under \(Artifacts.maxBody)"
            + " characters. It replaces the one you filed before, so there is only ever the"
            + " current one."
    }

    /// The subject the ask goes under, and what the person sees in the Messages panel.
    public static let statusReportSubject = "Status report"
}
