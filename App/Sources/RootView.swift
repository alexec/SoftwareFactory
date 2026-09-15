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
                ForEach(model.dashboard.agents(on: nil)) { agentRow($0, under: true) }

                // Alex, 12 Sep 2026: the count in the heading.
                Section("Projects (\(model.dashboard.projects.count))") {
                    ForEach(model.dashboard.projects) { status in
                        // The name, and whether it wants you. The dot and the counts of
                        // blocked and in progress were here and are gone: a sidebar is a
                        // list of places to go, and a row that also reports on the work
                        // makes you read twelve small numbers to find the one project you
                        // were looking for. What is left is the one thing you cannot act
                        // on anywhere else, a question waiting. (T358, Alex, 15 Sep 2026.)
                        HStack {
                            Text(status.project.name)
                                .foregroundStyle(status.project.onHold ? .secondary : .primary)
                            Spacer()
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
                        // The agents on it, working ones first. An agent belongs to the
                        // work it is doing: in one flat list of eight you read every row's
                        // project name to find the two on the thing you came for. (T359.)
                        ForEach(model.dashboard.agents(on: status.id)) { agentRow($0, under: true) }
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
                StatusReportsView(
                    selectAgent: { showAgent($0) },
                    selectProject: { id in
                        selection = id.map(Destination.project) ?? .noProject
                    })
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
            // An agent that has left, or one just deleted, lands you on the dashboard.
            // It used to land on Agents, which is not a row in the sidebar any more.
            case .agent(let id):
                if let agent = model.dashboard.agents.first(where: { $0.id == id }) {
                    // One page per agent, not one page that changes agents: the terminal
                    // inside it is a view SwiftUI holds on to, and going straight from
                    // one agent's row to another's left the old one on screen.
                    // (Alex, 14 Sep 2026.)
                    AgentView(status: agent, back: goBack)
                        .id(agent.id)
                } else {
                    dashboard
                }
            default:
                dashboard
            }
        }
        // The microphone sits over whatever page is open, bottom right, so a thought can
        // be said from wherever you happen to be standing. It is told which project you
        // are looking at, which is the project when the words do not name one. (T340.)
        .overlay(alignment: .bottomTrailing) {
            DictateButton(lookingAt: lookingAtProject)
                .padding(20)
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
    /// `under` is an agent sitting beneath its project: indented, and without the project
    /// name, which the row above it already says.
    private func agentRow(_ status: Dashboard.AgentStatus, under: Bool = false) -> some View {
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
                if !under {
                    Text(status.project?.name ?? "No project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
            // One line per task in its name, not just the one the factory calls
            // current: the others are in its name too, nobody else may take them, and
            // the only way to see them was to open its page. (T362.)
            ForEach(sidebarLines(status)) { line in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let number = line.number {
                        Text(number)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(line.words)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.leading, under ? 14 : 0)
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
    /// What the second line says: the task it is on, else the first line of its status
    /// report, else the terminal title. The rule is in the kit; this finds the report.
    /// (T295.)
    private func sidebarTitle(_ status: Dashboard.AgentStatus) -> String {
        AgentLine.underTheName(task: status.task, report: report(for: status), title: status.agent.title)
    }

    /// Everything in this agent's name, blocked first, or the one line it can say for
    /// itself when it holds nothing. (T362.)
    private func sidebarLines(_ status: Dashboard.AgentStatus) -> [AgentLine.Line] {
        AgentLine.linesUnderTheName(
            tasks: Backlog.alreadyYours(status.agent.id, in: model.snapshot.tasks),
            report: report(for: status),
            title: status.agent.title)
    }

    private func report(for status: Dashboard.AgentStatus) -> Artifact? {
        guard let projectID = status.agent.projectID else { return nil }
        return Artifacts.statusReport(by: status.agent.id, on: projectID, in: model.snapshot.artifacts)
    }

    /// The whole row in one line, for a row too narrow to show it.
    private func sidebarHelp(_ status: Dashboard.AgentStatus) -> String {
        let project = status.project?.name ?? "No project"
        let lines = sidebarLines(status).map { line in
            line.number.map { "\($0) \(line.words)" } ?? line.words
        }
        guard !lines.isEmpty else { return "\(status.agent.label), \(project)" }
        return ([status.agent.label + ", " + project] + lines).joined(separator: "\n")
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
            .glassEffect(.regular, in: .rect(cornerRadius: Style.card))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// The project whose page is open, if one is. An agent's page counts: the project it
    /// is on is the project you are looking at.
    private var lookingAtProject: String? {
        if case .project(let id) = selection { return id }
        if case .agent(let id) = selection {
            return model.snapshot.agents.first { $0.id == id }?.projectID
        }
        return nil
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
                // The cards, and the way to start another. That last card was on the
                // Agents page, which came off the sidebar in T360, and it was the only
                // way to start an agent that is not on a project.
                GlassEffectContainer(spacing: 16) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                        ForEach(agents) { status in
                            AgentCard(status: status, select: selectAgent)
                        }
                        FreeAgentCard()
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
