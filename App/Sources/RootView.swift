import SwiftUI
import SoftwareFactoryKit

enum Destination: Hashable {
    case dashboard
    case agents
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
                if !model.dashboard.agents.isEmpty {
                    Section("Agents (\(model.dashboard.agents.count))") {
                        ForEach(model.dashboard.agents) { agentRow($0) }
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
                    AgentView(status: agent, back: goBack)
                } else {
                    AgentsView { showAgent($0) }
                }
            default:
                dashboard
            }
        }
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
        .task(id: model.snapshot.agents.filter(\.wantsNudge).map(\.id)) {
            deliverPendingNudges(model: model, terminals: terminals)
        }
        .sheet(isPresented: Binding(get: { !model.hasSeenIntro }, set: { model.hasSeenIntro = !$0 })) {
            IntroSheet()
        }
    }

    /// One agent, in two lines: the project it is on, under it the line it set with an
    /// OSC title, with its bell in front when it rang for a look. Clicking it opens its
    /// page. (T222, T225, and Alex, 14 Sep 2026: two lines.)
    private func agentRow(_ status: Dashboard.AgentStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AgentActivityDot(activity: status.activity)
                Text(status.project?.name ?? "No project")
                    .foregroundStyle(status.activity == .stopped ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
            }
            HStack(spacing: 6) {
                if status.agent.bel { AgentBellMark() }
                Text(sidebarLine(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        }
        .help(sidebarLine(status))
        .tag(Destination.agent(status.id))
        .contextMenu {
            // The same poke as the button on its card and page: the words go in its
            // inbox and get typed into its terminal. (Alex, 14 Sep 2026.)
            if status.canNudge {
                Button("Nudge \(status.agent.label)") {
                    sendNudge(to: status.agent, model: model, terminals: terminals)
                }
            }
            Button("Delete \(status.agent.label)", role: .destructive) {
                model.delete(status.agent)
            }
        }
    }

    /// The second line of an agent's row: what it last said it was doing, and its own
    /// name until it has said anything, so the line is never empty.
    private func sidebarLine(_ status: Dashboard.AgentStatus) -> String {
        let title = status.agent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? status.agent.label : title
    }

    private var title: String {
        if case .project(let id) = selection, let p = model.project(for: id) { return p.name }
        if case .agents = selection { return "Agents" }
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
