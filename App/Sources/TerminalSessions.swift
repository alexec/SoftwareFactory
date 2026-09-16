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
        /// A fresh identity every time a terminal is actually started in this session.
        /// The session id is the agent's, and it is the same one before and after the
        /// agent is started back up, so it cannot be what the page keys its pane on: on
        /// a resume SwiftUI saw the same id, kept the view it already had, and went on
        /// showing the dead terminal while the new one ran unseen.
        /// (Alex, 14 Sep 2026: make sure that the terminal is updated in the UI.)
        var run = UUID()
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

    /// OSC 0/2 from the agent's terminal. Session id, then the title.
    var onTitle: ((String, String) -> Void)?
    /// BEL from the agent's terminal. Session id.
    var onBell: ((String) -> Void)?

    /// Starts `command` in the project's folder, in a session the agent names back to us
    /// through SOFTWARE_FACTORY_SESSION.
    @discardableResult
    func start(in project: Project, command: String, session: String, agentID: UUID? = nil) throws -> Session {
        guard let path = project.path, !path.isEmpty else { throw AgentLauncher.LaunchError.noFolder }
        return start(id: session, command: command, folder: path, projectID: project.id, agentID: agentID)
    }

    /// An agent on no project: a browser owner, a reviewer, anything that works across
    /// the factory. It starts in your home folder unless it is given one, which is what a
    /// shell opened beside an agent does. (Alex, 16 Sep 2026.)
    @discardableResult
    func start(prompt: String, session: String, agentID: UUID? = nil, folder: String? = nil,
               command: (String) -> String) -> Session {
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return start(id: session, command: command(words),
                     folder: folder ?? FileManager.default.homeDirectoryForCurrentUser.path,
                     projectID: nil, agentID: agentID)
    }

    /// The id is the one the agent was reserved with, so the record and the terminal say
    /// the same thing: the session is the agent.
    @discardableResult
    private func start(id: String, command: String, folder path: String, projectID: String?, agentID: UUID?) -> Session {
        let environment = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        // Through tmux when it is on, so the session belongs to its server and survives
        // this app quitting; as our own child when it is not. `exec` either way, so the
        // process is the agent and not a shell holding it.
        let line = Tmux.command(session: id, running: command, in: path) ?? "exec \(command)"
        // An interactive login shell, the same as a Terminal window: `zsh -lc` skips
        // ~/.zshrc, so ~/.local/bin is missing and claude is not found.
        // (Alex, 12 Sep 2026: the button looked dead because of this.)
        let terminal = hostedTerminal(id: id)
        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["-ilc", line],
            environment: environment,
            currentDirectory: path)
        let session = Session(id: id, projectID: projectID, started: .now, agentID: agentID, terminal: terminal)
        sessions[id] = session
        return session
    }

    /// One SwiftTerm view, wired so OSC titles and BEL reach the factory. Used for a
    /// fresh launch and for attaching to a session tmux kept.
    private func hostedTerminal(id: String) -> FactoryTerminalView {
        let terminal = FactoryTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        terminal.bellStyle = .none
        let watcher = Watcher(
            ended: { [weak self] in
                MainActor.assumeIsolated { self?.sessions[id]?.ended = .now }
            },
            titled: { [weak self] title in
                Task { @MainActor in self?.onTitle?(id, title) }
            }
        )
        terminal.onBell = { [weak self] in
            Task { @MainActor in self?.onBell?(id) }
        }
        terminal.processDelegate = watcher
        watchers[id] = watcher
        return terminal
    }

    /// The agent's own process, once its terminal is up. With `exec` the pane runs the
    /// agent itself, so this is the pid the factory records: it never has to ask the
    /// agent who it is. tmux takes a moment to have a pane, so this is worth a couple of
    /// tries before giving up. Never call it from the main thread: it runs tmux.
    /// (T-session, 13 Sep 2026.)
    nonisolated static func agentPID(session: String, tries: Int = 10) -> Int32? {
        for _ in 0..<tries {
            if let pid = Tmux.panePID(session: session), pid > 0 { return pid }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    @ObservationIgnored private var watchers: [String: Watcher] = [:]

    /// Hears the shell exit, and OSC titles.
    private final class Watcher: NSObject, LocalProcessTerminalViewDelegate {
        private let ended: @Sendable () -> Void
        private let titled: @Sendable (String) -> Void

        init(ended: @escaping @Sendable () -> Void, titled: @escaping @Sendable (String) -> Void) {
            self.ended = ended
            self.titled = titled
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            ended()
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            titled(title)
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }

    func session(_ id: String?) -> Session? {
        guard let id else { return nil }
        return sessions[id]
    }

    /// The terminal an agent is working in. The terminal is named after the agent, so
    /// this is a lookup and nothing more.
    ///
    /// It used to be a search. A terminal and the agent in it were two separate facts
    /// that had to be matched up: its own session if the terminal agreed it was this
    /// agent's, otherwise the oldest unclaimed session on its project started before it
    /// registered. All of that guessing existed because an agent could turn up in a
    /// window the factory had not put it in. It cannot now. (T-session, 13 Sep 2026.)
    func session(for agent: Agent) -> Session? { sessions[agent.id.uuidString] }

    /// The sessions tmux is holding, as of the last look. Asking tmux means running
    /// tmux, and running anything from a view means a beachball when the server is slow
    /// to answer, so the answer is kept here and the asking happens off the main thread.
    /// (Alex, 13 Sep 2026.)
    private(set) var held: Set<String> = []
    @ObservationIgnored private var isLooking = false
    @ObservationIgnored private var tmuxConfigLoaded = false

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
        let reload = !tmuxConfigLoaded
        tmuxConfigLoaded = true
        let holding = await Task.detached(priority: .utility) {
            if reload { Tmux.reloadConfig() }
            return Tmux.holding()
        }.value
        let names = Set(holding.map(\.session))
        if names != held { held = names }
        // The titles come back on the same ask, and this is the only place they come
        // from for an agent nobody is looking at: SwiftTerm hears an OSC title while it
        // is attached and nowhere else, so a card's line used to say whatever it last
        // said with its page open. (Alex, 15 Sep 2026.)
        for line in holding {
            if let title = line.title { onTitle?(line.session, title) }
        }
    }

    /// Picks a session back up after this app has been restarted: tmux still has it, so
    /// a new terminal attaches to what has been running all along. Only for a session we
    /// have already seen tmux holding, so this never waits on tmux to find out.
    @discardableResult
    func attach(_ id: String, folder: String? = nil) -> Session? {
        if let live = sessions[id] { return live }
        guard isHeld(id), let line = Tmux.attachCommand(session: id) else { return nil }
        let terminal = hostedTerminal(id: id)
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

    /// A line, and the return that submits it, sent as two writes with a gap between
    /// them.
    ///
    /// One write carrying the words and the return together arrives at the agent as a
    /// paste: every one of these CLIs reads its input in chunks, and a return inside a
    /// chunk is a newline in the box, not the key that sends it. The nudge sat there
    /// typed out and unsent. So the words go first, and the return follows on its own
    /// once the input has settled. Any newline inside the words is flattened for the
    /// same reason: this sends one line, and the only return is the one at the end.
    /// (Alex, 14 Sep 2026: the nudge does not send the right newline.)
    /// Answers whether there was a terminal to type into. A message for an agent whose
    /// window is not open has not been delivered and must not be marked as though it had.
    @discardableResult
    func sendLine(_ text: String, to id: String) -> Bool {
        guard sessions[id]?.terminal != nil else { return false }
        let line = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        send(line, to: id)
        _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .milliseconds(150))
            self?.send("\r", to: id)
        }
        return true
    }

    /// Control-C, for a session that has run away.
    func interrupt(_ id: String) {
        send("\u{03}", to: id)
    }

    /// Ends the session and forgets it. The agent stops where it stands, in tmux too.
    ///
    /// The pane this app holds goes first, so no page is left drawing a terminal that is
    /// about to die under it. Killing the tmux session runs tmux, which waits, so that
    /// half happens off the main thread and is waited for: the caller is usually about
    /// to start a new session under the same name, and `new-session -A` would attach to
    /// the old dead pane and run nothing.
    func end(_ id: String) async {
        sessions[id]?.terminal.terminate()
        sessions[id] = nil
        watchers[id] = nil
        await Task.detached(priority: .userInitiated) { Tmux.kill(id) }.value
        held.remove(id)
    }
}

/// SwiftTerm swallows BEL unless we override it: LocalProcessTerminalView does not
/// forward `bell` to its process delegate. We take BEL here and pass it up, with no
/// beep of our own.
final class FactoryTerminalView: LocalProcessTerminalView {
    var onBell: (() -> Void)?

    override func bell(source: Terminal) {
        onBell?()
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
