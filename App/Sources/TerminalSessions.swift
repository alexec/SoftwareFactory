import AppKit
import Observation
import SoftwareFactoryKit
import SwiftTerm
import SwiftUI

/// The terminals the app has started, one per agent it launched, kept here rather than in
/// a view so moving between pages leaves the agent working. They are children of this
/// app: quitting it ends them.
@Observable
@MainActor
final class TerminalSessions {
    /// A running session: the name the agent reports back, and the live terminal.
    struct Session: Identifiable {
        var id: String
        /// The project it was started for. Nil for an agent that works no project.
        var projectID: String?
        var started: Date
        /// The agent working in it, once one has registered. Agents that report
        /// SOFTWARE_FACTORY_SESSION say so themselves; the rest are matched by the
        /// project they turn up on. (Alex, 12 Sep 2026: they do not all report it.)
        var agentID: UUID?
        /// Set when the shell exits. The session stays so its last words can be read.
        var ended: Date?
        /// The view is the process: SwiftTerm holds the pty inside it, so it is made
        /// once and handed to whichever page is showing.
        var terminal: LocalProcessTerminalView
    }

    private(set) var sessions: [String: Session] = [:]

    /// Starts `command` in the project's folder, in a session the agent names back to us
    /// through SOFTWARE_FACTORY_SESSION.
    @discardableResult
    func start(in project: Project, command: String, session: String, agentID: UUID? = nil) throws -> Session {
        guard let path = project.path, !path.isEmpty else { throw AgentLauncher.LaunchError.noFolder }
        return start(id: session, command: command, folder: path, projectID: project.id, agentID: agentID)
    }

    /// An agent on no project: a browser owner, a reviewer, anything that works across
    /// the factory. It starts in your home folder.
    @discardableResult
    func start(prompt: String, session: String, agentID: UUID? = nil, command: (String) -> String) -> Session {
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return start(id: session, command: command(words),
                     folder: FileManager.default.homeDirectoryForCurrentUser.path,
                     projectID: nil, agentID: agentID)
    }

    /// The id is the one the agent was reserved with, so the record, the terminal and
    /// SOFTWARE_FACTORY_SESSION all say the same thing.
    @discardableResult
    private func start(id: String, command: String, folder path: String, projectID: String?, agentID: UUID?) -> Session {
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        environment.append("SOFTWARE_FACTORY_SESSION=\(id)")
        // Through tmux when it is on, so the session belongs to its server and survives
        // this app quitting; as our own child when it is not.
        let agent = "\(command); exec /bin/zsh -il"
        let line = Tmux.command(session: id, running: agent, in: path) ?? agent
        // An interactive login shell, the same as a Terminal window: `zsh -lc` skips
        // ~/.zshrc, so ~/.local/bin is missing and claude is not found.
        // (Alex, 12 Sep 2026: the button looked dead because of this.)
        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["-ilc", line],
            environment: environment,
            currentDirectory: path)
        let session = Session(id: id, projectID: projectID, started: .now, agentID: agentID, terminal: terminal)
        sessions[id] = session
        // The shell exiting is the session ending: the card stops pretending otherwise.
        let watcher = Watcher { [weak self] in
            MainActor.assumeIsolated { self?.sessions[id]?.ended = .now }
        }
        terminal.processDelegate = watcher
        watchers[id] = watcher
        return session
    }

    @ObservationIgnored private var watchers: [String: Watcher] = [:]

    /// Hears the shell exit, and says so.
    private final class Watcher: NSObject, LocalProcessTerminalViewDelegate {
        private let ended: @Sendable () -> Void

        init(ended: @escaping @Sendable () -> Void) { self.ended = ended }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            ended()
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }

    func session(_ id: String?) -> Session? {
        guard let id else { return nil }
        return sessions[id]
    }

    /// The terminal an agent is working in: the session it named, or the one this app
    /// started for its project just before it registered.
    func session(for agent: Agent) -> Session? {
        // Its own session, and only if the terminal agrees it is this agent's: two cards
        // sharing one window is worse than a card with no window.
        if let named = agent.session, let session = sessions[named],
           session.agentID == nil || session.agentID == agent.id {
            return session
        }
        return sessions.values.first { $0.agentID == agent.id }
    }

    /// Matches sessions to the agents that came out of them. An agent belongs to the
    /// oldest unclaimed session on its project that was started before it registered.
    func adopt(_ agents: [Dashboard.AgentStatus]) {
        let known = Set(sessions.values.compactMap(\.agentID))
        for status in agents where !known.contains(status.agent.id) {
            let agent = status.agent
            if let named = agent.session, let session = sessions[named] {
                // One terminal holds one agent. The factory clears the session off the
                // record that had it, so a session already bound stays where it is.
                if session.agentID == nil { sessions[named]?.agentID = agent.id }
                continue
            }
            let mine = sessions.values
                .filter { $0.agentID == nil && $0.ended == nil && $0.projectID == agent.projectID }
                .filter { $0.started <= agent.registered }
                .sorted { $0.started < $1.started }
            if let first = mine.first { sessions[first.id]?.agentID = agent.id }
        }
    }

    /// The sessions tmux is holding, as of the last look. Asking tmux means running
    /// tmux, and running anything from a view means a beachball when the server is slow
    /// to answer, so the answer is kept here and the asking happens off the main thread.
    /// (Alex, 13 Sep 2026.)
    private(set) var held: Set<String> = []
    @ObservationIgnored private var isLooking = false

    /// Whether a session this app has lost is still held by tmux, ready to attach to.
    /// A lookup, not a question: it never waits on anything.
    func isHeld(_ session: String) -> Bool { held.contains(session) }

    /// Asks tmux what it is holding, off the main thread, and remembers the answer. Safe
    /// to call as often as you like: one look runs at a time, and a wedged server times
    /// out rather than piling up.
    ///
    /// Whether an agent is still *running* is not asked here. That is the agent's pid on
    /// its record, and `Agent.hasExited` answers it: a terminal outliving its agent is
    /// the normal case, and an agent that has been resumed is not in the session it was
    /// launched in. (Alex, 13 Sep 2026.)
    func lookForHeldSessions() async {
        guard Tmux.isOn, !isLooking else { return }
        isLooking = true
        defer { isLooking = false }
        let names = await Task.detached(priority: .utility) { Set(Tmux.sessions()) }.value
        if names != held { held = names }
    }

    /// Picks a session back up after this app has been restarted: tmux still has it, so
    /// a new terminal attaches to what has been running all along. Only for a session we
    /// have already seen tmux holding, so this never waits on tmux to find out.
    @discardableResult
    func attach(_ id: String, folder: String? = nil) -> Session? {
        if let live = sessions[id] { return live }
        guard isHeld(id), let line = Tmux.attachCommand(session: id) else { return nil }
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        environment.append("SOFTWARE_FACTORY_SESSION=\(id)")
        terminal.startProcess(executable: "/bin/zsh", args: ["-ilc", line], environment: environment,
                              currentDirectory: folder ?? FileManager.default.homeDirectoryForCurrentUser.path)
        let session = Session(id: id, projectID: nil, started: .now, terminal: terminal)
        sessions[id] = session
        return session
    }

    /// Whether zmux is here at all, so sessions outlive this app.
    var keepsSessions: Bool { Tmux.isOn }

    /// The newest session started for a project, for the moments before its agent has
    /// registered and told us its name.
    func newest(for projectID: String) -> Session? {
        sessions.values.filter { $0.projectID == projectID }.max { $0.started < $1.started }
    }

    /// Sessions nobody has registered against yet, for the cards that stand in for them.
    /// One whose shell has exited is forgotten after a minute rather than sitting there.
    func starting(for projectID: String?, claimed: Set<String>, now: Date = .now) -> [Session] {
        sessions.values
            .filter { $0.projectID == projectID && $0.agentID == nil && !claimed.contains($0.id) }
            .filter { $0.ended.map { now.timeIntervalSince($0) < 60 } ?? true }
            .sorted { $0.started < $1.started }
    }

    /// Types into the session exactly as a person at the keyboard would: the bytes go to
    /// the pty, and the agent cannot tell the difference.
    func send(_ text: String, to id: String) {
        guard let terminal = sessions[id]?.terminal else { return }
        terminal.send(source: terminal, data: ArraySlice(Array(text.utf8)))
    }

    /// A line, with the return that submits it.
    func sendLine(_ text: String, to id: String) {
        send(text + "\r", to: id)
    }

    /// Control-C, for a session that has run away.
    func interrupt(_ id: String) {
        send("\u{03}", to: id)
    }

    /// Ends the session and forgets it. The agent stops where it stands, in tmux too.
    func end(_ id: String) {
        Tmux.kill(id)
        sessions[id]?.terminal.terminate()
        sessions[id] = nil
        watchers[id] = nil
    }
}

/// One live terminal, shown wherever its agent is. The same view travels between pages,
/// so what it has printed stays and what you type reaches the agent.
struct TerminalPanel: NSViewRepresentable {
    var terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        // Focus only when nothing else has it: taking it back on every redraw pulled the
        // caret out of whatever you were typing in. (Alex, 12 Sep 2026.)
        DispatchQueue.main.async {
            guard let window = terminal.window else { return }
            if window.firstResponder === window { window.makeFirstResponder(terminal) }
        }
        return terminal
    }

    // Nothing to update, and nothing to dismantle: the session outlives the page.
    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
}
