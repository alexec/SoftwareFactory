import SwiftUI
import SoftwareFactoryKit

enum Destination: Hashable {
    case dashboard
    /// Everybody's news on one page, reached from the agents tile on the dashboard. There
    /// was an Agents page beside it, a grid of the same cards the sidebar and each project
    /// already draw; it went in T392 rather than being given a door of its own.
    case statusReports
    case factory
    case noProject
    case project(String)
    case agent(UUID)
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(TerminalSessions.self) private var terminals
    @Environment(Floor.self) private var floor
    @Environment(AgentShells.self) private var shells
    @State private var selection: Destination? = .dashboard
    /// Where the agent page was opened from, so its back button returns there.
    @State private var cameFrom: Destination?
    // The macOS place for this is a right-click on the row, not a button on its own
    // page. (Alex, 12 Sep 2026.)
    @State private var removing: Project?
    /// The Archived section, shut until somebody opens it. Archived means hidden, and a
    /// section that opens itself is not hidden. (T415.)
    @State private var showingArchived = false
    /// The room the floating microphone needs at the foot of every page: its 44 points and
    /// the 20 of padding around it, less a little, because a page's own bottom margin is
    /// already there. (T471.)
    private static let microphone = 52.0
    @State private var addingProject = false
    @State private var newProjectName = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Dashboard", systemImage: "square.grid.2x2")
                    // What the dashboard is for: the questions waiting on you.
                    .badge(model.dashboard.openEscalations.count)
                    .tag(Destination.dashboard)
                HStack {
                    Label("Capacity", systemImage: "building.2")
                    Spacer()
                    CapacityDot(verdict: model.capacity, reason: model.capacityReason)
                }
                .tag(Destination.factory)

                // Only while there is somebody on it. An agent cannot be started on no
                // project any more, so this row is the last of the ones that were, and it
                // goes when they do rather than sitting there as a place you cannot get
                // to. (T411.)
                if !model.dashboard.unassignedIsEmpty {
                    HStack {
                        ActivityDot(activity: model.dashboard.unassignedActivity)
                        Text("No project")
                        Spacer()
                        Text(model.dashboard.unassignedAgents.count, format: .number)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color(.quiet))
                    }
                    .tag(Destination.noProject)
                    ForEach(model.dashboard.agents(on: nil)) { agentRow($0, under: true) }
                }

                // Alex, 12 Sep 2026: the count in the heading. The way to add one sits on
                // the heading too (T433): it was a toolbar button on the Dashboard, which
                // is a page about what needs you rather than the list of projects, so the
                // control was one page away from the thing it adds to.
                Section {
                    ForEach(model.dashboard.projects) { status in
                        // The name, how much is waiting on its backlog, and whether it
                        // wants you.
                        //
                        // The counts of blocked and in progress came off in T358, because
                        // a sidebar is a list of places to go and a row that reports on
                        // the work makes you read twelve small numbers to find the one
                        // project you were looking for. The backlog count is back because
                        // it answers a different question: not how the work is going, but
                        // where there is work left to pick up. It is quiet, grey and to
                        // the left of the orange, so the one thing you cannot act on
                        // anywhere else still reads first. (Alex, 16 Sep 2026.)
                        HStack(spacing: 6) {
                            Text(status.project.name)
                                .foregroundStyle(status.project.onHold ? .secondary : .primary)
                            Spacer(minLength: 4)
                            if status.backlogCount > 0 {
                                Text(status.backlogCount, format: .number)
                                    .font(.caption)
                                    .foregroundStyle(Color(.quiet))
                                    .monospacedDigit()
                                    .help(status.backlogCount == 1
                                          ? "1 task on the backlog"
                                          : "\(status.backlogCount) tasks on the backlog")
                            }
                            if status.openEscalations > 0 {
                                // A solid mark rather than a wash. A quarter-strength
                                // orange over dark paper is a shade of the ground, and
                                // this is the one number in the sidebar that has to be
                                // seen from across the room. (T408.)
                                Text(status.openEscalations, format: .number)
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Color(.paper))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(.alarm), in: .capsule)
                                    .help(status.openEscalations == 1
                                          ? "1 question waiting on you"
                                          : "\(status.openEscalations) questions waiting on you")
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
                } header: {
                    HStack(spacing: 4) {
                        Text("Projects (\(model.dashboard.projects.count))")
                        Spacer(minLength: 0)
                        Button("Add a project", systemImage: "plus") { addingProject = true }
                            .buttonStyle(.borderless)
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .help("Add a project by name")
                            .popover(isPresented: $addingProject, arrowEdge: .bottom) { newProject }
                    }
                }

                // Put away. Drawn only when there is something in it, and folded shut, so
                // an archived agent is hidden in the way Alex asked for and still has a
                // door: off every list with nowhere to be seen from is what T392 had to
                // fix. (T415.)
                if !model.dashboard.archived.isEmpty {
                    Section("Archived (\(model.dashboard.archived.count))", isExpanded: $showingArchived) {
                        ForEach(model.dashboard.archived) { agent in
                            archivedRow(agent)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .scrollContentBackground(.hidden)
            .background(Color(.paper))
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
            case .statusReports:
                StatusReportsView(
                    selectAgent: { showAgent($0) },
                    selectProject: { id in
                        selection = id.map(Destination.project) ?? .noProject
                    },
                    back: { selection = .dashboard })
            case .factory:
                FactoryView()
            case .noProject:
                // Nobody left on it means the page has nothing to say, and the row it was
                // reached from has gone too.
                if model.dashboard.unassignedIsEmpty {
                    dashboard
                } else {
                    NoProjectView { showAgent($0) }
                }
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
        //
        // And the page is given room for it rather than losing whatever was in that
        // corner. Seen on screen: a question card's Answer with this button read "Answer
        // with th…" under the microphone, which is the one control on that card you press.
        // A safe area inset does it for every page at once, and keeps the button where
        // T340 wanted it. (T471.)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: Self.microphone)
        }
        .overlay(alignment: .bottomTrailing) {
            DictateButton(lookingAt: lookingAtProject)
                .padding(20)
        }
        // The house paper, under the whole window. Liquid Glass keeps its translucency
        // and sits on this rather than replacing it, so the theme is what shows through
        // the glass instead of a second idea beside it, and the rust is the app's tint so
        // every control picks it up. (Alex, 16 Sep 2026: use it everywhere.)
        .background(Color(.paper))
        .tint(Color(.mark))
        .safeAreaInset(edge: .top) { writeFailure }
        .navigationTitle(title)
        // Nothing in the middle of the title bar. The two counts that lived there,
        // documents nobody has read and messages not yet delivered, were a third place
        // reporting what is waiting, after the Dashboard and the sidebar's own badges.
        // One class of fact, one altitude. (T434, Alex, 15 Sep 2026.)
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
        // What the daemon is holding. On its own clock rather than on the store's,
        // because an agent's state changes without anything being written down: a child
        // exits, a permission request arrives, a turn ends. (T373.)
        .task {
            while !Task.isCancelled {
                await floor.look()
                model.noteFloor(Array(floor.held.values))
                // A permission request is not a question in a list: the agent is blocked
                // until it is answered, so it goes where every other question goes and
                // can be answered from the floor, the phone or the Lock Screen. (T373.)
                model.syncPermissions(floor)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: model.snapshot.agents.filter(\.wantsLaunch).map(\.id)) {
            await StartAgent.launchPending(model: model, terminals: terminals, floor: floor)
        }
        .task(id: model.snapshot.agents.flatMap { model.undelivered(for: $0.id) }.map(\.id)) {
            await deliverPendingMessages(model: model, terminals: terminals, floor: floor)
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
                        .foregroundStyle(Color(.quiet))
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
                            .foregroundStyle(Color(.faint))
                    }
                    Text(line.words)
                        .font(.caption)
                        .foregroundStyle(Color(.quiet))
                        .lineLimit(1)
                        // The front of a sentence is what you read. Middle truncation is
                        // for a path, where both ends identify it, and it was cutting
                        // "Four pushed: T3...ecord (686bfb3)" out of the middle of prose.
                        // (T407.)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.leading, under ? 14 : 0)
        .help(sidebarHelp(status))
        .tag(Destination.agent(status.id))
        .contextMenu {
            // The same poke as the button on its card and page: the words are written
            // down and typed into its terminal. (Alex, 14 Sep 2026.)
            // Stop ends its process where it stands; Delete takes the record away too.
            // (T261.)
            if status.canResume {
                Button("Start \(status.agent.label)") {
                    Task { _ = await StartAgent.resume(agent: status.agent, model: model, terminals: terminals, floor: floor) }
                }
            }
            if status.canStop {
                Button("Stop \(status.agent.label)", role: .destructive) {
                    stopAgent(status.agent, model: model, floor: floor)
                }
            }
            // Between Stop and Delete: stopped, and off every list, with everything it
            // wrote kept. (T415.)
            if Agents.mayArchive(status.agent) {
                Button("Archive \(status.agent.label)") {
                    stopAgent(status.agent, model: model, floor: floor)
                    model.archive(status.agent)
                }
            }
            Button("Delete \(status.agent.label)", role: .destructive) {
                stopAgent(status.agent, model: model, floor: floor)
                floor.forget(status.agent.id)
                shells.closeAll(for: status.agent.id, terminals: terminals)
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

    /// A project is a name: an app, a role that spans apps, a piece of tooling.
    private var newProject: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A project is a name: an app, a role across apps, a piece of tooling. Agents file against it by that name.")
                .font(.callout)
                .foregroundStyle(Color(.quiet))
                .fixedSize(horizontal: false, vertical: true)
            TextField("Project name", text: $newProjectName)
                .onSubmit(addProject)
            HStack {
                Spacer()
                Button("Cancel") { addingProject = false }
                Button("Add", action: addProject)
                    .buttonStyle(.glassProminent)
                    .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Style.cardPadding)
        .frame(width: 320)
    }

    private func addProject() {
        model.addProject(named: newProjectName)
        newProjectName = ""
        addingProject = false
    }

    /// One agent that has been put away: its name, quietly, and the two things left to do
    /// with it. No dot and no line underneath, because neither is news about an agent that
    /// is not working. (T415.)
    private func archivedRow(_ agent: Agent) -> some View {
        Text(agent.label)
            .foregroundStyle(Color(.quiet))
            .lineLimit(1)
            .truncationMode(.middle)
            .help("Archived \(agent.archivedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")")
            .contextMenu {
                Button("Unarchive \(agent.label)") { model.unarchive(agent) }
                Button("Delete \(agent.label)", role: .destructive) {
                    floor.forget(agent.id)
                    shells.closeAll(for: agent.id, terminals: terminals)
                    model.delete(agent)
                }
            }
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
        if case .statusReports = selection { return "Status reports" }
        if case .factory = selection { return "Capacity" }
        if case .noProject = selection { return "No project" }
        if case .agent(let id) = selection,
           let agent = model.dashboard.agents.first(where: { $0.id == id }) {
            return agent.agent.label
        }
        return "Taktu: Software Factory"
    }

    /// What the factory is holding that has not reached you: documents nobody has opened
    /// and messages still to be typed into a terminal. Beside the factory's own name,
    /// because neither has a page of its own to say so from: a document lands on a
    /// project you are not looking at and a message waits for an agent whose terminal is
    /// off screen. Nothing is drawn when there is nothing waiting, the way the bell is
    /// nothing until an agent rings it. (T373.)
    @ViewBuilder

    private var dashboard: some View {
        DashboardView { selection = .statusReports }
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
                    .foregroundStyle(Color(.alarm))
                VStack(alignment: .leading, spacing: 2) {
                    Text("That change was not saved.")
                        .font(.headline)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Color(.quiet))
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

    /// Back to the page the agent was opened from, or the dashboard if there is no telling.
    private func goBack() {
        selection = cameFrom ?? .dashboard
        cameFrom = nil
    }
}

/// The agents that were started before a project was required, and nothing else.
///
/// There is no way to make another: every launch now names a project, so this page has no
/// Launch card on it and the sidebar row above it is drawn only while somebody is still
/// here. When the last one stops, the row and this page go with it. (T411, Alex,
/// 15 Sep 2026: make projects required.)
struct NoProjectView: View {
    @Environment(AppModel.self) private var model
    var selectAgent: (UUID) -> Void = { _ in }

    private var agents: [Dashboard.AgentStatus] { model.dashboard.unassignedAgents }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    ActivityDot(activity: model.dashboard.unassignedActivity)
                    Text("No project")
                        .font(.title3.weight(.semibold))
                }
                Text("These were started before a project was required. Nothing new lands here.")
                    .font(.callout)
                    .foregroundStyle(Color(.quiet))
                GlassEffectContainer(spacing: 16) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                        ForEach(agents) { status in
                            AgentCard(status: status, select: selectAgent)
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

