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
    @discardableResult
    static func run(
        project: Project,
        task: FactoryTask? = nil,
        agent: LaunchAgent,
        style: AppModel.LaunchStyle,
        model: AppModel,
        terminals: TerminalSessions
    ) -> String? {
        let cap = Agents.cap(model.throttle)
        if Agents.atCap(model.snapshot.agents, cap: cap) { return Agents.fullMessage(cap: cap) }
        guard let reserved = model.reserveAgent(for: project) else {
            return model.storeError ?? "The agent could not be written down. The store said no."
        }
        let session = reserved.id
        if let task { model.assign(task, to: reserved) }
        let command = agent.launchCommand(for: project, task: task, as: reserved.label, session: session)
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

    /// Agents `agent_create` asked for: written down already, waiting for a terminal.
    /// Uses the last coding agent the person launched, and the in-app vs Terminal style
    /// they have set. (T179, 13 Sep 2026.)
    static func launchPending(model: AppModel, terminals: TerminalSessions) {
        let pending = model.snapshot.agents.filter(\.wantsLaunch)
        for agent in pending {
            model.clearLaunchRequest(agent)
            guard let projectID = agent.projectID,
                  let project = model.project(for: projectID) else { continue }
            let kind = LaunchAgent.remembered(UserDefaults.standard.string(forKey: lastLaunchAgentKey))
            let task = agent.taskID.flatMap { id in model.snapshot.tasks.first { $0.id == id } }
            let command = kind.launchCommand(for: project, task: task, as: agent.label, session: agent.id)
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
