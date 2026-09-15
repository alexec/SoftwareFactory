import SwiftUI
import SoftwareFactoryKit

enum Destination: Hashable {
    case dashboard
    case agents
    case statusReports
    case inProgress
    case factory
    case noProject
    case project(String)
    case agent(UUID)
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(TerminalSessions.self) private var terminals
    @State private var selection: Destination? = .dashboard
    /// Where the agent page was opened from, so its back button returns there.
    @State private var cameFrom: Destination?
    // The macOS place for this is a right-click on the row, not a button on its own
    // page. (Alex, 12 Sep 2026.)
    @State private var removing: Project?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Dashboard", systemImage: "square.grid.2x2")
                    // What the dashboard is for: the questions waiting on you.
                    .badge(model.dashboard.openEscalations.count)
                    .tag(Destination.dashboard)
                Label("Agents", systemImage: "person.2")
                    .badge(model.dashboard.agents.count)
                    .tag(Destination.agents)
                // The badge counts the agents that have not said anything recently, not
                // the reports: a row that only ever says how many agents there are is one
                // nobody opens. (T288.)
                Label("Status reports", systemImage: "text.document")
                    .badge(StatusReportBoard.quiet(in: model.snapshot, now: .now))
                    .tag(Destination.statusReports)
                // The badge counts what is in progress with nobody on it, for the same
                // reason the one above counts the quiet agents. (T287.)
                Label("In progress", systemImage: "hammer")
                    .badge(WorkInProgress.orphaned(in: model.snapshot))
                    .tag(Destination.inProgress)
                HStack {
                    Label("Capacity", systemImage: "building.2")
                    Spacer()
                    CapacityDot(verdict: model.capacity, reason: model.capacityReason)
                }
                .tag(Destination.factory)

                HStack {
                    ActivityDot(
                        activity: model.dashboard.unassignedActivity,
                        isEmpty: model.dashboard.unassignedIsEmpty)
                    Text("No project")
                    Spacer()
                    if !model.dashboard.unassignedIsEmpty {
                        Text(model.dashboard.unassignedAgents.count, format: .number)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(Destination.noProject)

                // The floor, in a group of its own. (Alex, 14 Sep 2026: back out of the
                // projects, two lines each.)
                // Running and stopped are kept apart: a stopped agent is not gone, it
                // is waiting to be started back up, and among the working ones it read
                // as one of them. (T268.)
                if !model.dashboard.runningAgents.isEmpty {
                    Section("Agents (\(model.dashboard.runningAgents.count))") {
                        ForEach(model.dashboard.runningAgents) { agentRow($0) }
                    }
                }
                if !model.dashboard.stoppedAgents.isEmpty {
                    Section("Stopped (\(model.dashboard.stoppedAgents.count))") {
                        ForEach(model.dashboard.stoppedAgents) { agentRow($0) }
                    }
                }

                // Alex, 12 Sep 2026: the count in the heading.
                Section("Projects (\(model.dashboard.projects.count))") {
                    ForEach(model.dashboard.projects) { status in
                        HStack {
                            ActivityDot(activity: status.activity, isEmpty: status.isEmpty, onHold: status.project.onHold)
                            Text(status.project.name)
                                .foregroundStyle(status.project.onHold ? .secondary : .primary)
                            Spacer()
                            ProgressNumbers(status: status, compact: true)
                            if status.openEscalations > 0 {
                                Text(status.openEscalations, format: .number)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange.opacity(0.25), in: .capsule)
                            }
                        }
                        .tag(Destination.project(status.id))
                        .contextMenu {
                            Button("Remove project…", role: .destructive) { removing = status.project }
                                .disabled(!model.openTasks(in: status.project).isEmpty)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .confirmationDialog("Remove \(removing?.name ?? "") from the factory?",
                                 isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Remove", role: .destructive) {
                    if let removing { model.removeProject(removing) }
                    removing = nil
                }
            } message: {
                Text("It leaves every list, with its done and parked tasks. Nothing is deleted from disk.")
            }
        } detail: {
            switch selection {
            case .agents:
                AgentsView { showAgent($0) }
            case .statusReports:
                StatusReportsView { showAgent($0) }
            case .inProgress:
                InProgressView { selection = .project($0) }
            case .factory:
                FactoryView()
            case .noProject:
                NoProjectView { showAgent($0) }
            case .project(let id):
                if let project = model.project(for: id) {
                    ProjectView(project: project) { showAgent($0) }
                } else {
                    dashboard
                }
            // An agent that has left, or one just deleted, lands you back on Agents.
            case .agent(let id):
                if let agent = model.dashboard.agents.first(where: { $0.id == id }) {
                    // One page per agent, not one page that changes agents: the terminal
                    // inside it is a view SwiftUI holds on to, and going straight from
                    // one agent's row to another's left the old one on screen.
                    // (Alex, 14 Sep 2026.)
                    AgentView(status: agent, back: goBack)
                        .id(agent.id)
                } else {
                    AgentsView { showAgent($0) }
                }
            default:
                dashboard
            }
        }
        .safeAreaInset(edge: .top) { writeFailure }
        .navigationTitle(title)
        // What tmux is holding and which agents are actually running, kept fresh off
        // the main thread so the cards can say so without anybody waiting on tmux or ps.
        // A process dies between one look and the next, so this is on a clock rather
        // than waiting for the set of agents to change. (Alex, 13 Sep 2026.)
        .onAppear {
            terminals.onTitle = { model.setTitle(session: $0, title: $1) }
            terminals.onBell = { model.ring(session: $0) }
        }
        .task {
            while !Task.isCancelled {
                await terminals.lookForHeldSessions()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: model.snapshot.agents.filter(\.wantsLaunch).map(\.id)) {
            StartAgent.launchPending(model: model, terminals: terminals)
        }
        .task(id: model.snapshot.agents.flatMap { model.undelivered(for: $0.id) }.map(\.id)) {
            deliverPendingMessages(model: model, terminals: terminals)
        }
        .sheet(isPresented: Binding(get: { !model.hasSeenIntro }, set: { model.hasSeenIntro = !$0 })) {
            IntroSheet()
        }
    }

    /// One agent, in two lines: its name and the project it is on, under them the line it
    /// set with an OSC title. The name is on the row because that is what an agent is
    /// called everywhere else: in its own page's title, in a nudge, in `agent_list`, and in
    /// every message between agents. Reading it off the title line only worked for an agent
    /// that had not set one. The bell sits with the activity dot, which is where the rest
    /// of the status is, and because the title line is not there at all until the agent
    /// sets one. Clicking it opens its page.
    /// (T222, T225, Alex 14 Sep 2026: two lines, then: show the agent A<n>.)
    private func agentRow(_ status: Dashboard.AgentStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AgentActivityDot(activity: status.activity)
                // An agent that registered before numbers has its raw id for a label, so this
                // truncates rather than forcing a UUID's width on the whole sidebar. It
                // takes the space it needs before the project name does.
                Text(status.agent.label)
                    .foregroundStyle(status.activity == .stopped ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                AgentBellMark(ringing: status.agent.bel)
                Text(status.project?.name ?? "No project")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            if !sidebarTitle(status).isEmpty {
                Text(sidebarTitle(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(sidebarHelp(status))
        .tag(Destination.agent(status.id))
        .contextMenu {
            // The same poke as the button on its card and page: the words are written
            // down and typed into its terminal. (Alex, 14 Sep 2026.)
            if status.canNudge {
                Button("Nudge \(status.agent.label)") {
                    sendNudge(to: status.agent, model: model, terminals: terminals)
                }
            }
            // Stop ends its process where it stands; Delete takes the record away too.
            // (T261.)
            if status.canResume {
                Button("Start \(status.agent.label)") {
                    Task { _ = await StartAgent.resume(agent: status.agent, model: model, terminals: terminals) }
                }
            }
            if status.canStop {
                Button("Stop \(status.agent.label)", role: .destructive) {
                    model.stop(status.agent)
                }
            }
            Button("Delete \(status.agent.label)", role: .destructive) {
                model.delete(status.agent)
            }
        }
    }

    /// The second line of an agent's row: what it last said it was doing, and its own
    /// name until it has said anything, so the line is never empty.
    /// The line the agent set with an OSC title, or nothing. The name is on the row above
    /// now, so there is no need to fall back to it and repeat it.
    private func sidebarTitle(_ status: Dashboard.AgentStatus) -> String {
        status.agent.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The whole row in one line, for a row too narrow to show it.
    private func sidebarHelp(_ status: Dashboard.AgentStatus) -> String {
        let title = sidebarTitle(status)
        let project = status.project?.name ?? "No project"
        return title.isEmpty ? "\(status.agent.label), \(project)" : "\(status.agent.label), \(project): \(title)"
    }

    private var title: String {
        if case .project(let id) = selection, let p = model.project(for: id) { return p.name }
        if case .agents = selection { return "Agents" }
        if case .statusReports = selection { return "Status reports" }
        if case .inProgress = selection { return "In progress" }
        if case .factory = selection { return "Capacity" }
        if case .noProject = selection { return "No project" }
        if case .agent(let id) = selection,
           let agent = model.dashboard.agents.first(where: { $0.id == id }) {
            return agent.agent.label
        }
        return "Taktu: Software Factory"
    }

    private var dashboard: some View {
        DashboardView()
    }

    /// A write that did not happen, said where the person is standing. Editing or
    /// deleting a task went through `persist`, which caught the error and then refreshed,
    /// and the refresh cleared it again: the row redrew exactly as it was and nothing
    /// anywhere said why. A change that did not take has to say so on the page that
    /// looks unchanged. (T264, Alex, 15 Sep 2026.)
    @ViewBuilder private var writeFailure: some View {
        if let error = model.writeError {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("That change was not saved.")
                        .font(.headline)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("OK") { model.clearWriteError() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(in: .rect(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func showAgent(_ id: UUID) {
        cameFrom = selection
        selection = .agent(id)
    }

    /// Back to the page the agent was opened from, or Agents if there is no telling.
    private func goBack() {
        selection = cameFrom ?? .agents
        cameFrom = nil
    }
}

/// Agents that registered with no project: the same cards as a project page, no backlog.
struct NoProjectView: View {
    @Environment(AppModel.self) private var model
    var selectAgent: (UUID) -> Void = { _ in }

    private var agents: [Dashboard.AgentStatus] { model.dashboard.unassignedAgents }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    ActivityDot(
                        activity: model.dashboard.unassignedActivity,
                        isEmpty: model.dashboard.unassignedIsEmpty)
                    Text("No project")
                        .font(.title3.weight(.semibold))
                }
                if agents.isEmpty {
                    EmptyLine(text: "No agents without a project.", symbol: "person.2")
                } else {
                    GlassEffectContainer(spacing: 16) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                            ForEach(agents) { status in
                                AgentCard(status: status, select: selectAgent)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A project's dot: the same four colours an agent's dot uses, because a project is
/// whatever its agents are. Nobody on it draws nothing.
struct ActivityDot: View {
    var activity: Dashboard.ProjectActivity
    var isEmpty = false
    var onHold = false

    var body: some View {
        Group {
            if isEmpty && !onHold {
                Circle().fill(.clear)
            } else {
                Circle().fill(AgentActivityDot.color(activity))
            }
        }
        .frame(width: 8, height: 8)
        .help(help)
    }

    private var help: String {
        if onHold { return "On hold" }
        if isEmpty { return "Nobody is on it" }
        return AgentActivityDot.help(activity)
    }
}
