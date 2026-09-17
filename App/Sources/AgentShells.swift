import AppKit
import Observation
import SwiftUI
import SoftwareFactoryKit

/// The terminals a person has opened beside an agent, in that agent's folder.
///
/// A shell used to be a kind of agent, which it never was: it registered with nothing,
/// was told nothing, held no task and had no conversation to pick back up, so every
/// question asked of `LaunchAgent` had to be answered "except for that one". What a
/// person actually wants is to run something by hand in the folder an agent is working
/// in, next to it, and watch both. So a terminal is opened beside an agent now, as many
/// as you like, as tabs. (Alex, 16 Sep 2026.)
@Observable
@MainActor
final class AgentShells {
    /// One shell: the terminal session that runs it, and what to call the tab.
    struct Shell: Identifiable, Hashable {
        var id: String
        var number: Int
        var folder: String
        var name: String { "Shell \(number)" }
    }

    private(set) var byAgent: [UUID: [Shell]] = [:]
    /// Which tab is showing, per agent, so moving between pages comes back to the same
    /// one.
    var showing: [UUID: String] = [:]

    func shells(for agent: UUID) -> [Shell] { byAgent[agent] ?? [] }

    func has(_ agent: UUID) -> Bool { !(byAgent[agent] ?? []).isEmpty }

    /// Where a shell opens: the project's folder, or your home when the agent is on no
    /// project or the project has no folder set. A shell always has somewhere to start,
    /// so clicking the terminal icon is never a dead end. (Alex, 16 Sep 2026.)
    static func folder(_ wanted: String?) -> String {
        guard let wanted, !wanted.isEmpty, FileManager.default.fileExists(atPath: wanted)
        else { return FileManager.default.homeDirectoryForCurrentUser.path }
        return wanted
    }

    /// Opens one in the agent's folder. The id is the session's, and it is not the
    /// agent's own id: an agent has one session and a person may want three shells.
    @discardableResult
    func open(for agent: UUID, in wanted: String?, terminals: TerminalSessions) -> Shell? {
        let folder = Self.folder(wanted)
        var mine = byAgent[agent] ?? []
        let shell = Shell(id: "shell-\(UUID().uuidString)",
                          number: (mine.map(\.number).max() ?? 0) + 1,
                          folder: folder)
        // An interactive login shell, the same as a Terminal window. Nothing is typed
        // into it and nothing is printed in it: a terminal that opens with somebody
        // else's instructions in it is a terminal pretending to be an agent.
        terminals.start(prompt: "", session: shell.id, folder: folder) { _ in "zsh -il" }
        mine.append(shell)
        byAgent[agent] = mine
        showing[agent] = shell.id
        return shell
    }

    /// Closes one, and whatever is running in it.
    func close(_ shell: Shell, for agent: UUID, terminals: TerminalSessions) {
        var mine = byAgent[agent] ?? []
        mine.removeAll { $0.id == shell.id }
        byAgent[agent] = mine.isEmpty ? nil : mine
        if showing[agent] == shell.id { showing[agent] = mine.last?.id }
        _Concurrency.Task { await terminals.end(shell.id) }
    }

    /// Everything this agent had, for one that has been deleted.
    func closeAll(for agent: UUID, terminals: TerminalSessions) {
        for shell in byAgent[agent] ?? [] {
            _Concurrency.Task { await terminals.end(shell.id) }
        }
        byAgent[agent] = nil
        showing[agent] = nil
    }
}

/// The shells beside one agent: a row of tabs, and the one showing underneath.
struct AgentShellsPane: View {
    @Environment(TerminalSessions.self) private var terminals
    @Environment(AgentShells.self) private var shells
    var agent: Agent
    /// The folder a new one opens in. Nil when the agent is on no project, and then
    /// there is nothing to open.
    var folder: String?

    private var mine: [AgentShells.Shell] { shells.shells(for: agent.id) }

    private var current: AgentShells.Shell? {
        mine.first { $0.id == shells.showing[agent.id] } ?? mine.first
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Divider()
            if let current, let session = terminals.session(current.id) {
                TerminalPanel(terminal: session.terminal)
                    .id(session.run)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // A terminal, not an offer of one. Opening this pane with nothing in it used to
        // show a button saying Open a shell, which is the pane asking you to confirm the
        // thing you just asked for. (Alex, 16 Sep 2026.)
        .task(id: agent.id) {
            if mine.isEmpty { shells.open(for: agent.id, in: folder, terminals: terminals) }
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(mine) { shell in
                    let isShowing = shell.id == current?.id
                    HStack(spacing: 5) {
                        Button(shell.name) { shells.showing[agent.id] = shell.id }
                            .buttonStyle(.plain)
                            .font(.caption.weight(isShowing ? .semibold : .regular))
                        Button {
                            shells.close(shell, for: agent.id, terminals: terminals)
                        } label: {
                            Image(systemName: "xmark").font(Style.Text.tiny)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Close \(shell.name)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isShowing ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                in: .capsule)
                }
                Button {
                    shells.open(for: agent.id, in: folder, terminals: terminals)
                } label: {
                    Image(systemName: "plus").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open another shell in \(Projects.shortPath(AgentShells.folder(folder)))")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
    }
}
