import AppKit
import Foundation
import SoftwareFactoryKit

/// Starts an agent in the project's folder, in a Terminal window of its own so the
/// session outlives this app. A script is written and opened rather than Terminal being
/// told what to type: no Apple Events, so no consent dialog.
///
/// Sandboxed, none of this works: the child would inherit the sandbox and lose ~/.claude,
/// the keychain and every tool the agent runs. There the button copies the command
/// instead and the person pastes it themselves.
enum AgentLauncher {
    /// True when the app is running inside the sandbox, where a launched agent could not
    /// reach your own environment.
    static let isSandboxed = NSHomeDirectory().contains("/Library/Containers/")

    enum LaunchError: LocalizedError {
        case noFolder

        var errorDescription: String? {
            switch self {
            case .noFolder: "Set the project's folder first: an agent has to start somewhere."
            }
        }
    }

    /// Opens Terminal in the project's folder running `command`.
    static func launch(_ project: Project, command: String) throws {
        guard let path = project.path, !path.isEmpty else { throw LaunchError.noFolder }
        let script = try write(command: command, in: path, for: project)
        NSWorkspace.shared.open(script)
    }

    /// One command on the clipboard, as it is.
    static func copyCommand(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// The command on the clipboard, for a sandboxed build or a person who would rather
    /// paste it into a window they already have open.
    static func copy(_ project: Project, command: String) {
        let path = project.path ?? "."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("cd \(shellQuoted(path)) && \(command)", forType: .string)
    }

    private static func write(command: String, in path: String, for project: Project) throws -> URL {
        let folder = URL.cachesDirectory.appending(path: "Launch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(fileName(for: project)).command")
        let script = """
        #!/bin/zsh
        cd \(shellQuoted(path)) || exit 1
        exec \(command)

        """
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// One script per project, rewritten each time, so the Terminal window's title says
    /// which project it is.
    private static func fileName(for project: Project) -> String {
        let safe = project.name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let name = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? "project" : name
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Starting an agent, from wherever the person clicked: a project's page, or one task on
/// its backlog. One place, so the agent is written down, given its name, handed its task
/// and started the same way every time.
@MainActor
enum StartAgent {
    /// Reserves the agent, puts the task in its name when there is one, and starts it.
    /// Returns what went wrong, or nil when it started.
    ///
    /// The task is assigned rather than claimed: whether a task is in progress is the
    /// agent's word, not ours. Assigned, `task_next` hands it to this agent and passes
    /// over it for everyone else.
    /// `words` is what the person wrote in the launch popover, which starts as the words
    /// the factory would have used. Empty means they left it alone. Whatever it says, the
    /// line naming the agent and its session goes in front of it: that part is the
    /// factory's, not theirs. (T260.)
    @discardableResult
    static func run(
        project: Project,
        task: FactoryTask? = nil,
        agent: LaunchAgent,
        style: AppModel.LaunchStyle,
        model: AppModel,
        terminals: TerminalSessions,
        floor: Floor,
        words: String = "",
        /// What to run it on and how much it may do, as the person set them in the bar
        /// they started it from. Empty means the floor's own answer: the model Settings
        /// holds for that CLI, and the mode that matches what agents may do. (T466.)
        runOn: String? = nil,
        mode: String = ""
    ) async -> String? {
        let cap = Agents.cap(model.throttle)
        if Agents.atCap(model.snapshot.agents, cap: cap) { return Agents.fullMessage(cap: cap) }
        guard let reserved = model.reserveAgent(for: project) else {
            return model.writeError ?? "The agent could not be written down. The store said no."
        }
        let session = reserved.id
        // A shell is not given a task: nothing in it would read one.
        if let task { model.assign(task, to: reserved) }
        model.remember(agent, for: reserved)
        let asked = words.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = asked.isEmpty
            ? (task.map { LaunchPrompt.task($0, in: project, as: reserved.label, session: session) }
                ?? LaunchPrompt.project(project, as: reserved.label, session: session))
            : LaunchPrompt.free(asked, as: reserved.label, session: session)
        // An agent that speaks ACP goes to the daemon, which holds its process so it
        // outlives this app. Everything above this line is the same either way: the cap,
        // the reservation, the number, the task, the words. (T373.)
        if agent.speaksACP, style == .embedded, !AgentLauncher.isSandboxed {
            guard let path = project.path, !path.isEmpty else {
                return AgentLauncher.LaunchError.noFolder.localizedDescription
            }
            // No session in the words: it is handed its own MCP address, so the factory
            // knows who is calling without being told. (T373.)
            let acpPrompt = asked.isEmpty
                ? (task.map { LaunchPrompt.task($0, in: project, as: reserved.label) }
                    ?? LaunchPrompt.project(project, as: reserved.label))
                : LaunchPrompt.named(asked, as: reserved.label)
            model.setRuntime(.acp, for: reserved)
            if let wrong = await floor.start(reserved, kind: agent, cwd: path, words: acpPrompt,
                                             model: runOn ?? model.model(for: agent), mode: mode) {
                model.setRuntime(.terminal, for: reserved)
                return wrong
            }
            model.rememberACPSession(floor.running(reserved.id)?.session, for: reserved)
            return nil
        }
        let command = agent.command(for: prompt, session: session)
        guard !AgentLauncher.isSandboxed else {
            AgentLauncher.copy(project, command: command)
            return nil
        }
        do {
            switch style {
            case .embedded:
                try terminals.start(in: project, command: command, session: session.uuidString, agentID: reserved.id)
                model.findTheProcess(for: reserved)
            case .terminal: try AgentLauncher.launch(project, command: command)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Starts a stopped agent back up, in the conversation it was already having. The
    /// session id it was launched with is what makes that possible: `--resume <session>`
    /// finds exactly the one the factory has a record for, and the agent comes back
    /// knowing who it is and what it was doing. Cursor is the exception and picks up the
    /// newest chat in the folder, which is that agent's, because a terminal holds one
    /// agent.
    ///
    /// The old tmux session is killed first. It is still there, holding a dead pane, and
    /// `new-session -A` would attach to that and run nothing. (T262.)
    @discardableResult
    static func resume(agent: Agent, model: AppModel, terminals: TerminalSessions, floor: Floor) async -> String? {
        guard Agents.mayResume(agent) else { return "\(agent.label) is not stopped." }
        let kind = LaunchAgent.remembered(agent.launchedWith)
        // The protocol's own resume: `session/load` on the session the agent minted,
        // capability-gated, rather than `--resume` and a guess. (T373.)
        if agent.speaksACP, !AgentLauncher.isSandboxed {
            guard let path = agent.projectID.flatMap({ model.project(for: $0) })?.path, !path.isEmpty else {
                return "\(agent.label) has no folder to start in."
            }
            return await floor.start(agent, kind: kind, cwd: path, words: LaunchPrompt.carryOn,
                                     model: model.model(for: kind), resuming: true)
        }
        let command = kind.resumeCommand(session: agent.id)
        guard !AgentLauncher.isSandboxed else {
            if let project = agent.projectID.flatMap({ model.project(for: $0) }) {
                AgentLauncher.copy(project, command: command)
            } else {
                AgentLauncher.copyCommand(command)
            }
            return nil
        }
        await terminals.end(agent.id.uuidString)
        do {
            switch model.launchStyle {
            case .embedded:
                if let project = agent.projectID.flatMap({ model.project(for: $0) }) {
                    try terminals.start(in: project, command: command, session: agent.id.uuidString, agentID: agent.id)
                } else {
                    terminals.start(prompt: "", session: agent.id.uuidString, agentID: agent.id) { _ in command }
                }
            case .terminal:
                guard let project = agent.projectID.flatMap({ model.project(for: $0) }) else {
                    return "\(agent.label) is on no project, so there is no folder to start it in. Switch to in-app terminals to start it."
                }
                try AgentLauncher.launch(project, command: command)
            }
            model.findTheProcess(for: agent)
            // And it is told to carry on. It goes in as a message like any other, so it
            // is typed in when the new terminal appears rather than at whatever moment
            // this returns.
            //
            // Starting one used to type nothing in, on the argument that a factory
            // putting words in an agent's mouth the moment it wakes is one you cannot
            // start without committing to. What that gave instead was an agent sitting at
            // a prompt doing nothing until somebody noticed and nudged it, which is the
            // same commitment made twice. (T364; Alex, 14 Sep 2026, the other way.)
            model.sendMessage(to: agent.id, subject: "Started", contents: LaunchPrompt.carryOn)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Agents `agent_create` asked for: written down already, waiting for a terminal.
    /// Uses the last coding agent the person launched, and the in-app vs Terminal style
    /// they have set. (T179, 13 Sep 2026.)
    static func launchPending(model: AppModel, terminals: TerminalSessions, floor: Floor) async {
        let pending = model.snapshot.agents.filter(\.wantsLaunch)
        for agent in pending {
            model.clearLaunchRequest(agent)
            guard let projectID = agent.projectID,
                  let project = model.project(for: projectID) else { continue }
            // An agent asked for this one, so it gets an agent: the last coding agent the
            // person picked, never the terminal.
            let remembered = LaunchAgent.remembered(UserDefaults.standard.string(forKey: lastLaunchAgentKey))
            let kind = remembered
            let task = agent.taskID.flatMap { id in model.snapshot.tasks.first { $0.id == id } }
            model.remember(kind, for: agent)
            let prompt = task.map { LaunchPrompt.task($0, in: project, as: agent.label, session: agent.id) }
                ?? LaunchPrompt.project(project, as: agent.label, session: agent.id)
            if kind.speaksACP, model.launchStyle == .embedded, !AgentLauncher.isSandboxed,
               let path = project.path, !path.isEmpty {
                let acpPrompt = task.map { LaunchPrompt.task($0, in: project, as: agent.label) }
                    ?? LaunchPrompt.project(project, as: agent.label)
                model.setRuntime(.acp, for: agent)
                if let wrong = await floor.start(agent, kind: kind, cwd: path, words: acpPrompt, model: model.model(for: kind)) {
                    model.setRuntime(.terminal, for: agent)
                    model.noteError(wrong)
                } else {
                    model.rememberACPSession(floor.running(agent.id)?.session, for: agent)
                }
                continue
            }
            let command = kind.command(for: prompt, session: agent.id)
            guard !AgentLauncher.isSandboxed else {
                AgentLauncher.copy(project, command: command)
                continue
            }
            do {
                switch model.launchStyle {
                case .embedded:
                    try terminals.start(in: project, command: command, session: agent.id.uuidString, agentID: agent.id)
                    model.findTheProcess(for: agent)
                case .terminal:
                    try AgentLauncher.launch(project, command: command)
                }
            } catch {
                model.noteError(error.localizedDescription)
            }
        }
    }
}
