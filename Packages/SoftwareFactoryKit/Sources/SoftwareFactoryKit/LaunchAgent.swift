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

    /// What this one is, in a sentence or two, for the help page. Not shown on the launch
    /// popover: picking an agent is a working screen, and a paragraph you read and
    /// dismiss on every launch is a paragraph in the way. (Alex, 16 Sep 2026.)
    public var explanation: String {
        switch self {
        case .claudeCode:
            "Anthropic's CLI. It speaks ACP, so the factory hands it the tools as it starts and its page shows the work it is doing rather than a terminal."
        case .copilot:
            "GitHub's CLI. It speaks ACP, so the factory hands it the tools as it starts and its page shows the work it is doing rather than a terminal."
        case .grok:
            "xAI's CLI. It speaks ACP, so the factory hands it the tools as it starts and its page shows the work it is doing rather than a terminal."
        case .cursor:
            "Cursor's CLI. It speaks ACP, so the factory hands it the tools as it starts and its page shows the work it is doing rather than a terminal."
        case .terminal:
            "Not an agent. A shell in the project's folder that shows up on the floor like anything else, so you can run something by hand and watch it from the same page as the rest. Nothing is started in it and nothing is said to it."
        }
    }

    /// What has to be run once before this one can be launched, and what it is for. Empty
    /// for a plain shell, which needs nothing.
    public var setUp: [(what: String, command: String)] {
        var steps: [(String, String)] = []
        if let install = acpInstall { steps.append(("The part that speaks ACP", install)) }
        if let setup = setupCommand, !speaksACP { steps.append(("Register the factory with it", setup)) }
        return steps
    }

    // MARK: Speaking ACP

    /// What to run to get this agent as an ACP server on a pipe, or nil for one that
    /// does not speak it and has to keep its terminal.
    ///
    /// Checked against the real binaries on 16 Sep 2026, and then checked again: all four
    /// answer, each behind a different word. Reading `--help` for "acp" found two of them
    /// and missed the two that put it behind a subcommand, which is a good argument for
    /// handshaking with a thing rather than grepping its help. (T373, Alex, 16 Sep 2026.)
    public var acp: ACPLaunch? {
        switch self {
        // Zed's adapter on the Claude Agent SDK, `npm i -g @agentclientprotocol/claude-agent-acp`.
        case .claudeCode: ACPLaunch(command: "claude-agent-acp", arguments: [])
        // First-party, and the one every shape in `ACP` was first read off.
        case .copilot: ACPLaunch(command: "copilot", arguments: ["--acp"])
        // First-party, and the most forthcoming of the four: it reports resume as well as
        // loadSession, and hands back its models and its commands at initialize.
        case .grok: ACPLaunch(command: "grok", arguments: ["agent", "stdio"])
        // First-party. loadSession but no resume, so Start replays rather than picking up
        // where it left off, which is still the protocol answering instead of `--continue`
        // and a guess about which chat was this agent's. (T206 is finally closed.)
        case .cursor: ACPLaunch(command: "cursor-agent", arguments: ["acp"])
        // Not an agent. A shell has nothing to say to anybody.
        case .terminal: nil
        }
    }

    public var speaksACP: Bool { acp != nil }

    /// How to get the ACP half of this agent, for the agent that has not got it.
    public var acpInstall: String? {
        switch self {
        // The only one of the four that speaks it through something you install
        // separately. The rest have it built in.
        case .claudeCode: "npm install -g @agentclientprotocol/claude-agent-acp"
        case .copilot, .grok, .cursor, .terminal: nil
        }
    }

    public struct ACPLaunch: Sendable, Equatable {
        /// The binary's name. The daemon looks it up on the path itself, because it is
        /// started by the app and inherits none of a login shell.
        public var command: String
        public var arguments: [String]
        public init(command: String, arguments: [String]) {
            self.command = command
            self.arguments = arguments
        }
    }

    /// Anything a shell has to take literally.
    public static func quoted(_ words: String) -> String {
        "'" + words.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
