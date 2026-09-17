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
        + " " + askThroughTheFactory
    }

    /// The same line for an agent the factory hands its own MCP address to. It does not
    /// need to be told a session, because it never has to say one: the factory knows who
    /// is calling from the address the call arrived at. Two thirds of that sentence was
    /// an id for a person to read and an instruction to hold on to it. (T373.)
    static func youAreNamed(_ name: String) -> String {
        "You are agent \"\(name)\". The factory's tools already know it is you, so there "
        + "is nothing to register, nothing to say goodbye to and no id to keep."
        + " " + askThroughTheFactory
    }

    /// Where a question goes, said in the words an agent starts with.
    ///
    /// An agent that asks in its own interface and waits has asked nobody: that question
    /// is drawn in its terminal, or inside whatever its CLI puts on screen, and it reaches
    /// only somebody already looking at that one agent. A question raised with
    /// `escalation_raise` is a record in the store, so it is on the Needs you strip, in a
    /// banner, on the phone and on the Lock Screen, and it can be answered from a pocket.
    /// Alex is away from the Mac most of the day, which is the whole argument.
    ///
    /// And raising is not waiting. The agent files the question and picks up something
    /// else; the factory blocks the task on the decision and unblocks it when the answer
    /// lands. An agent sitting on a question all night is a slot, a terminal and a piece of
    /// work stopped for nothing. (T422, Alex, 15 Sep 2026.)
    static let askThroughTheFactory =
        "When you need the user to decide something, raise it with escalation_raise, "
        + "giving the options and your recommendation, and carry on with something else. "
        + "Do not ask in your own interface and wait for a reply: a question asked there "
        + "reaches nobody unless they are watching you, and the factory's one reaches them "
        + "wherever they are."

    /// An agent reached at its own address needs no session in its words.
    public static func project(_ project: Project, as name: String) -> String {
        named(projectWork(project), as: name)
    }

    public static func task(_ task: FactoryTask, in project: Project, as name: String) -> String {
        named(taskWork(task, in: project), as: name)
    }

    public static func named(_ prompt: String, as name: String) -> String {
        youAreNamed(name) + " \(prompt)"
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
            + " Claim it, read its note, and say when it is done."
            + " The note says what to produce, where it matters."
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
    /// front of it, which is what `project` and `task` are both built on and what an
    /// agent launched with the words edited gets.
    public static func free(_ prompt: String, as name: String, session: UUID) -> String {
        youAre(name, session) + " \(prompt)"
    }

    // The nudge is gone (T470). Its words were "The user has nudged you to continue your
    // work", and after T412 took the button off the agent's page the user was neither
    // sender: what was left was the factory poking an idle agent and one agent poking
    // another, both of them telling an agent a person had asked when nobody had. What an
    // agent gets instead is a message, which says who it is from and what they want.

    /// What an agent is told when the person starts it back up. Its conversation is on
    /// screen again and the CLI is sitting at a prompt waiting, which from the outside
    /// looks exactly like an agent that has stopped working.
    ///
    /// Starting one used to type nothing in, on the argument that a factory putting words
    /// in an agent's mouth the moment it wakes is one you cannot start without committing
    /// to. What that gave instead was an agent sitting there doing nothing until somebody
    /// noticed and nudged it, which is the same commitment made twice. (T364, and Alex,
    /// 14 Sep 2026, the other way.)
    public static let carryOn = "The user has started you back up. Carry on with your work."

    /// The lines the factory types in itself. They say who they are from in their own
    /// words, so they go into the terminal bare rather than wrapped in an attribution.
    /// The lines the factory types in itself. One now: the poke and the nudge were two
    /// and the nudge went in T470.
    public static let pokes: Set<String> = [carryOn]

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
