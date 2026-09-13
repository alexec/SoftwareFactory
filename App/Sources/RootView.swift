import SwiftUI
import SoftwareFactoryKit

enum Destination: Hashable {
    case dashboard
    case agents
    case factory
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
        // Agents turn up a second or two after the session that started them.
        .onChange(of: model.dashboard.agents.map(\.id)) { terminals.adopt(model.dashboard.agents) }
        // What tmux is holding, kept fresh off the main thread so the cards can say
        // whether an agent's terminal is here without anybody waiting on tmux.
        .task(id: model.dashboard.agents.map(\.id)) { await terminals.lookForHeldSessions() }
        .sheet(isPresented: Binding(get: { !model.hasSeenIntro }, set: { model.hasSeenIntro = !$0 })) {
            IntroSheet()
        }
    }

    private var title: String {
        if case .project(let id) = selection, let p = model.project(for: id) { return p.name }
        if case .agents = selection { return "Agents" }
        if case .factory = selection { return "Capacity" }
        if case .agent(let id) = selection,
           let agent = model.dashboard.agents.first(where: { $0.id == id }) {
            return agent.agent.name
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
