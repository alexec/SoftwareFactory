import Foundation

/// The coding agents the factory can start: Claude Code, GitHub Copilot, Grok, Cursor.
/// Chosen at launch, not as a setting, so a session can pick a different one each time.
///
/// A plain shell used to be one of these, and it never was one. It registered with
/// nothing, was told nothing, held no task and had no conversation to resume, so every
/// question asked of this type had to be answered "except for that one". A terminal is
/// something you open beside an agent now, in the same folder, which is what it was
/// always for. (Alex, 16 Sep 2026.)
public enum LaunchAgent: String, CaseIterable, Identifiable, Sendable, Hashable {
    case claudeCode
    case copilot
    case grok
    case cursor

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
        }
    }

    public var installURL: URL? {
        switch self {
        case .claudeCode: URL(string: "https://code.claude.com/docs/en/quickstart")!
        case .copilot: URL(string: "https://docs.github.com/en/copilot/get-started/cli-quickstart")!
        case .grok: URL(string: "https://docs.x.ai/build/overview")!
        case .cursor: URL(string: "https://cursor.com/docs/cli/installation")!
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
        }
    }

    /// What has to be run once before this one can be launched, and what it is for. Empty
    /// for a plain shell, which needs nothing, and for the three that need nothing but
    /// themselves.
    ///
    /// There used to be a second step here, a plugin install that registered the factory
    /// with the agent: `claude plugin marketplace add`, and one like it for each of the
    /// others. It is gone. `session/new` carries the factory's MCP server, so an ACP agent
    /// is handed its tools as it starts, and all four of ours speak ACP. (T373.)
    public var setUp: [(what: String, command: String)] {
        acpInstall.map { [("The part that speaks ACP", $0)] } ?? []
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
        }
    }

    public var speaksACP: Bool { acp != nil }

    /// How this agent is told which model to use, measured on each binary on 15 Sep 2026
    /// rather than read: `copilot --model <model>`, `grok -m, --model <MODEL>` and
    /// `cursor-agent --model <model>` all take one on the command line. Zed's adapter for
    /// Claude Code takes no arguments at all and prints no help; the SDK behind it reads
    /// `ANTHROPIC_MODEL`, so that one is set in the environment instead.
    ///
    /// **A model is chosen when an agent starts, not during its conversation.** Only Grok
    /// says anything about models over the protocol, and it does it in a vendor extension
    /// rather than in ACP's own `providers`, which Claude Code declares and leaves empty
    /// (T428). So there is nothing to change mid-session on three of the four, and a
    /// control that works on one agent is not a control. (T462.)
    public enum HowToSayTheModel: Sendable, Equatable {
        case flag(String)
        case environment(String)
    }

    public var howToSayTheModel: HowToSayTheModel {
        switch self {
        case .claudeCode: .environment("ANTHROPIC_MODEL")
        case .copilot, .grok, .cursor: .flag("--model")
        }
    }

    /// The arguments to start this agent with, given a model the person named. Empty means
    /// the CLI's own default, which is what nearly every agent should run on.
    public func acpLaunch(model: String?) -> ACPLaunch? {
        guard let launch = acp else { return nil }
        let model = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, case .flag(let flag) = howToSayTheModel else { return launch }
        return ACPLaunch(command: launch.command, arguments: launch.arguments + [flag, model])
    }

    /// What to put in the environment for it, for the one whose adapter takes no arguments.
    public func environment(model: String?) -> [String: String] {
        let model = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, case .environment(let name) = howToSayTheModel else { return [:] }
        return [name: model]
    }

    /// The modes this agent offers, as it named them, measured by handshaking each binary
    /// and reading `availableModes` off its `session/new` answer on 15 Sep 2026.
    /// `Tools/acp-modes.py` is what measured them and is how to measure them again.
    ///
    /// They are written down because the person picks a mode **before** the agent starts,
    /// and until it has handshaken nobody knows what it offers. What comes back at
    /// `session/new` is still the truth: a mode named here that the agent no longer offers
    /// is refused by `AgentFloor` and the agent follows the floor's setting instead, which
    /// is what it did before there was a choice at all. So a stale list here costs a menu
    /// row, not a wrong mode.
    ///
    /// The four do not mean the same things by them. Claude Code's are about how much it
    /// may do; Copilot's are about how it converses, and its ids are URLs; Cursor's are
    /// two thirds about that too, with Ask meaning it changes nothing. Grok offers none,
    /// which is why nothing is drawn for it. (T466.)
    public var modesOffered: [ACP.Mode] {
        switch self {
        case .claudeCode:
            [ACP.Mode(id: "default", name: "Manual", detail: "Always ask before making changes"),
             ACP.Mode(id: "acceptEdits", name: "Accept edits", detail: "Automatically accept all file edits"),
             ACP.Mode(id: "plan", name: "Plan", detail: "Create a plan before making changes"),
             ACP.Mode(id: "auto", name: "Auto", detail: "Claude handles permission decisions"),
             ACP.Mode(id: "bypassPermissions", name: "Bypass permissions", detail: "Accepts all permissions")]
        case .copilot:
            [ACP.Mode(id: "https://agentclientprotocol.com/protocol/session-modes#agent",
                      name: "Agent", detail: "Default agent mode for conversational interactions"),
             ACP.Mode(id: "https://agentclientprotocol.com/protocol/session-modes#plan",
                      name: "Plan", detail: "Plan mode for creating and executing multi-step plans"),
             ACP.Mode(id: "https://agentclientprotocol.com/protocol/session-modes#autopilot",
                      name: "Autopilot", detail: "Allows everything and runs to the end without stopping to ask (experimental)")]
        case .grok:
            []
        case .cursor:
            [ACP.Mode(id: "agent", name: "Agent", detail: "Full agent capabilities with tool access"),
             ACP.Mode(id: "plan", name: "Plan", detail: "Read-only mode for planning and designing before implementation"),
             ACP.Mode(id: "ask", name: "Ask", detail: "Q&A mode - no edits or command execution")]
        }
    }

    /// How to get the ACP half of this agent, for the agent that has not got it.
    public var acpInstall: String? {
        switch self {
        // The only one of the four that speaks it through something you install
        // separately. The rest have it built in.
        case .claudeCode: "npm install -g @agentclientprotocol/claude-agent-acp"
        case .copilot, .grok, .cursor: nil
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
