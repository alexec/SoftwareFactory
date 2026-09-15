import Foundation

/// What the factory can start in a terminal it owns: Claude Code, GitHub Copilot, Grok,
/// Cursor, or a plain shell. Chosen at launch, not as a setting, so a session can pick a
/// different one each time.
public enum LaunchAgent: String, CaseIterable, Identifiable, Sendable, Hashable {
    case claudeCode
    case copilot
    case grok
    case cursor
    /// No agent at all: a shell in the project's folder, on the floor like any other, so
    /// you can run something by hand and watch it from the same page as the rest.
    /// Nothing registers, nothing is told anything, and there is no plugin to install.
    /// (Alex, 15 Sep 2026.)
    case terminal

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
        case .cursor: "Cursor"
        case .terminal: "Terminal"
        }
    }

    /// Whether this one is an agent at all. A terminal takes no prompt, registers with
    /// nothing and has no conversation to resume: it is a shell.
    public var isCodingAgent: Bool { self != .terminal }

    /// Nil for a terminal: zsh is already there.
    public var installURL: URL? {
        switch self {
        case .claudeCode: URL(string: "https://code.claude.com/docs/en/quickstart")!
        case .copilot: URL(string: "https://docs.github.com/en/copilot/get-started/cli-quickstart")!
        case .grok: URL(string: "https://docs.x.ai/build/overview")!
        case .cursor: URL(string: "https://cursor.com/docs/cli/installation")!
        case .terminal: nil
        }
    }

    /// The command that registers this factory with the agent, once. Nil for a terminal:
    /// there is nothing in it to register.
    public var setupCommand: String? {
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
        case .cursor:
            "cursor-agent plugin marketplace add https://github.com/alexec/SoftwareFactory"
        case .terminal:
            nil
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
    /// `--resume <session>` picks up exactly the one the factory has a record for. Claude
    /// Code, Copilot and Grok all take a UUID here and refuse anything else, which is why
    /// the session is a UUID at all. (Alex, 13 Sep 2026.)
    ///
    /// Cursor is the one that cannot: `cursor-agent` makes its own chat id and will only
    /// resume one it made, so the factory's session reaches it in the words it starts
    /// with and nowhere else. That is enough, because the prompt is what every tool call
    /// is signed with. What it costs is the exact resume: `--continue` picks up the newest
    /// chat in that folder, which is that agent's, because a terminal holds one agent.
    ///
    /// Grok's `--trust` is folder trust for the current working directory, which is
    /// already the project's folder: project hooks, skills, MCP and instructions load
    /// without a prompt. The flag takes no path. (T180) Cursor wants three: `--force` to
    /// run commands without asking, `--trust` for the folder, and `--approve-mcps` so the
    /// factory's own MCP connection loads without a prompt. (T206)
    public func command(for prompt: String, session: UUID) -> String {
        let quoted = Self.quoted(prompt)
        let id = session.uuidString
        switch self {
        case .claudeCode: return "claude --session-id \(id) --permission-mode=auto \(quoted)"
        case .copilot: return "copilot --session-id \(id) --allow-all --interactive \(quoted)"
        case .grok: return "grok --session-id \(id) --always-approve --trust \(quoted)"
        case .cursor: return "cursor-agent --force --trust --approve-mcps \(quoted)"
        // A shell is told nothing. The words are dropped rather than echoed: a terminal
        // that opens with somebody else's instructions printed in it is a terminal
        // pretending to be an agent.
        case .terminal: return "zsh -il"
        }
    }

    /// Picking an agent back up where it left off, in the session the factory knows it
    /// by. Only an agent the factory started can be resumed: the id has to have been
    /// given at launch, because none of these CLIs will tell you one after the fact.
    /// Cursor is the exception, and resumes the newest chat in the folder instead.
    public func resumeCommand(session: UUID) -> String {
        switch self {
        case .claudeCode: return "claude --resume \(session.uuidString) --permission-mode=auto"
        case .copilot: return "copilot --resume=\(session.uuidString) --allow-all --interactive"
        case .grok: return "grok --resume \(session.uuidString) --always-approve --trust"
        case .cursor: return "cursor-agent --continue --force --trust --approve-mcps"
        // A shell that has exited has nothing to pick up. Start gives you a new one in
        // the same place.
        case .terminal: return "zsh -il"
        }
    }

    /// Anything a shell has to take literally.
    public static func quoted(_ words: String) -> String {
        "'" + words.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
