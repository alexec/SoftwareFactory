import Foundation

/// A coding agent the person can start from the factory: Claude Code, GitHub Copilot
/// or Grok. Chosen at launch, not as a setting, so a session can pick a different one
/// each time.
public enum LaunchAgent: String, CaseIterable, Identifiable, Sendable, Hashable {
    case claudeCode
    case copilot
    case grok

    public var id: String { rawValue }

    /// The last one the person picked, or Claude Code if they have not picked yet
    /// or the stored value is not one we launch. (T170, 13 Sep 2026.)
    public static func remembered(_ raw: String?) -> LaunchAgent {
        LaunchAgent(rawValue: raw ?? "") ?? .claudeCode
    }

    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .copilot: "GitHub Copilot"
        case .grok: "Grok"
        }
    }

    public var installURL: URL {
        switch self {
        case .claudeCode: URL(string: "https://code.claude.com/docs/en/quickstart")!
        case .copilot: URL(string: "https://docs.github.com/en/copilot/get-started/cli-quickstart")!
        case .grok: URL(string: "https://docs.x.ai/build/overview")!
        }
    }

    /// The command that registers this factory with the agent, once.
    public var setupCommand: String {
        switch self {
        case .claudeCode:
            """
            claude plugin marketplace add alexec/SoftwareFactory && \
            claude plugin install software-factory@software-factory-plugins
            """
        case .copilot:
            "copilot plugin install alexec/SoftwareFactory:Plugins/software-factory"
        case .grok:
            "grok plugin install alexec/SoftwareFactory#Plugins/software-factory --trust"
        }
    }

    /// What Launch an agent runs, once the shell is already in the project's folder.
    /// The prompt names the project, so an agent starts on the right backlog without
    /// being asked. (Alex, 12 Sep 2026.) Given a task, it names that instead: the
    /// task is already in the agent's name, so it is told which one to claim.
    public func launchCommand(for project: Project, task: FactoryTask? = nil, as name: String, session: UUID) -> String {
        if let task { return command(for: LaunchPrompt.task(task, in: project, as: name, session: session), session: session) }
        return command(for: LaunchPrompt.project(project, as: name, session: session), session: session)
    }

    /// The same agent, told something else: a browser owner, a reviewer, whatever
    /// the person types.
    ///
    /// The session is named on the command line as well as in the prompt, so the agent's
    /// own conversation carries the factory's id. That is what makes an agent resumable:
    /// `--resume <session>` picks up exactly the one the factory has a record for. All
    /// three CLIs take a UUID here and refuse anything else, which is why the session is
    /// a UUID at all. (Alex, 13 Sep 2026.)
    ///
    /// Grok's `--trust` is folder trust for the current working directory, which is
    /// already the project's folder: project hooks, skills, MCP and instructions load
    /// without a prompt. The flag takes no path. (T180)
    public func command(for prompt: String, session: UUID) -> String {
        let quoted = Self.quoted(prompt)
        let id = session.uuidString
        switch self {
        case .claudeCode: return "claude --session-id \(id) --permission-mode=auto \(quoted)"
        case .copilot: return "copilot --session-id \(id) --allow-all --interactive \(quoted)"
        case .grok: return "grok --session-id \(id) --always-approve --trust \(quoted)"
        }
    }

    /// Picking an agent back up where it left off, in the session the factory knows it
    /// by. Only an agent the factory started can be resumed: the id has to have been
    /// given at launch, because none of these CLIs will tell you one after the fact.
    public func resumeCommand(session: UUID) -> String {
        switch self {
        case .claudeCode: return "claude --resume \(session.uuidString) --permission-mode=auto"
        case .copilot: return "copilot --resume=\(session.uuidString) --allow-all --interactive"
        case .grok: return "grok --resume \(session.uuidString) --always-approve --trust"
        }
    }

    /// Anything a shell has to take literally.
    public static func quoted(_ words: String) -> String {
        "'" + words.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
