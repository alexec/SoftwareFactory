import AppKit
import SwiftUI
import SoftwareFactoryKit

/// The dashboard: the numbers, then what needs you. The agents have a page
/// of its own.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var addingProject = false
    @State private var newProjectName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                summary
                needsYou
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolbar {
            ToolbarItem {
                Button("Add a project", systemImage: "plus") { addingProject = true }
                    .help("Add a project by name")
                    .popover(isPresented: $addingProject, arrowEdge: .bottom) { newProject }
            }
        }
    }

    // MARK: Summary

    private var summary: some View {
        let d = model.dashboard
        // Tiles wrap onto a second row in a narrow window rather than squeezing their words.
        return GlassEffectContainer(spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) {
                StatTile(value: d.inProgress, label: d.inProgress == 1 ? "task in progress" : "tasks in progress", symbol: "hammer")
                StatTile(value: d.openEscalations.count, label: d.openEscalations.count == 1 ? "needs you" : "need you",
                         symbol: "questionmark.bubble", tint: d.openEscalations.isEmpty ? nil : .orange)
                StatTile(value: d.agents.count, label: d.agents.count == 1 ? "agent registered" : "agents registered", symbol: "person.2")
                StatTile(value: d.heldCount, label: d.heldCount == 1 ? "resource held" : "resources held", symbol: "lock.rectangle.stack")
            }
        }
        .frame(maxWidth: 900)
    }

    // MARK: Needs you

    @ViewBuilder
    private var needsYou: some View {
        let open = model.dashboard.openEscalations
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Needs you")
                    .font(.title2.weight(.semibold))
                if !open.isEmpty {
                    Text("Click an option and the agent is told.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if model.notifier.standing == .notAsked {
                NotificationPrimer()
            }
            if open.isEmpty {
                EmptyLine(text: "Nothing needs you.", symbol: "checkmark.circle")
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(open) { escalation in
                            EscalationCard(escalation: escalation, showsProject: true)
                                .frame(width: 380)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    /// A project is a name: an app, a role that spans apps, a piece of tooling.
    private var newProject: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A project is a name: an app, a role across apps, a piece of tooling. Agents file against it by that name.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
        .padding(16)
        .frame(width: 320)
    }

    private func addProject() {
        model.addProject(named: newProjectName)
        newProjectName = ""
        addingProject = false
    }

}

struct StatTile: View {
    var value: Int
    var label: String
    var symbol: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(value, format: .number)
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .contentTransition(.numericText())
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassEffect(glass, in: .rect(cornerRadius: 18))
        .animation(.snappy, value: value)
    }

    private var glass: Glass {
        if let tint { return .regular.tint(tint.opacity(0.18)) }
        return .regular
    }
}

struct EmptyLine: View {
    var text: String
    var symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
            Text(text)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }
}

/// One agent: who it is, what it is on, and when it last said anything.
/// The whole card opens the agent.
struct AgentCard: View {
    /// Every card on the grid is this tall, whatever it has to say: the middle two lines
    /// are given the room and the text truncates into it, so a long description cannot
    /// push one card past its neighbours. (Alex, 13 Sep 2026.)
    static let height: CGFloat = 132
    /// What it says it is, and what it is on: two lines, always.
    static let middle: CGFloat = 40

    @Environment(AppModel.self) private var model
    @Environment(TerminalSessions.self) private var terminals
    var status: Dashboard.AgentStatus
    var select: (UUID) -> Void

    /// Whether there is a terminal to look at right now. Every agent is one the factory
    /// started, so this is no longer a question about where the agent came from: it is
    /// only whether the window is still here to watch. (T-session, 13 Sep 2026.)
    private var hasTerminal: Bool {
        terminals.session(for: status.agent) != nil
            || terminals.isHeld(status.agent.id.uuidString)
    }

    /// Its process has gone. Worth saying out loud: the terminal outlives the agent by
    /// design, so a window that is still there proves nothing, and until now a stopped
    /// agent looked exactly like a quiet one for the hour it takes the factory to give
    /// up on it. An agent that never reported a pid says nothing either way rather than
    /// being called dead. (Alex, 13 Sep 2026.)
    private var hasStopped: Bool { status.activity == .stopped }

    var body: some View {
        Button {
            model.clearBell(status.agent)
            select(status.agent.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AgentActivityDot(activity: status.activity)
                    Text(status.agent.label)
                        .font(.headline)
                    if hasStopped { StoppedMark() }
                    AgentBellMark(ringing: status.agent.bel)
                    Spacer(minLength: 0)
                }
                Text(status.project?.name ?? "No project")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 2) {
                    if !status.agent.title.isEmpty {
                        Text(status.agent.title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(status.agent.title)
                    }
                    if let task = status.task {
                        Text(task.title)
                            .font(.callout)
                            .lineLimit(1)
                            .help(task.title)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: Self.middle, alignment: .topLeading)
                HStack(spacing: 6) {
                    // Where it runs, so you know before you click whether there is a
                    // terminal on its page or only what it has told the factory. The
                    // symbol says it and the tooltip spells it out: the words sat on
                    // every card saying the same thing, and the time needs the room.
                    // (Alex, 13 Sep 2026.)
                    Image(systemName: hasTerminal ? "macwindow" : "arrow.up.forward.app")
                        .help(hasTerminal
                              ? "Its terminal is here: its page shows it working, and you can type to it"
                              : "Its terminal has gone: its page shows what it has told the factory, and nothing to type into")
                    // The cards go down to 190 points wide, so on the narrowest one the
                    // time drops its prefix rather than losing its last characters;
                    // "2 minutes ago" reads as a last seen on its own.
                    // (A9, 13 Sep 2026: T157.)
                    let lastSeen = status.agent.lastSeen.formatted(.relative(presentation: .named))
                    ViewThatFits(in: .horizontal) {
                        Text("Last seen \(lastSeen)")
                        Text(lastSeen)
                    }
                    .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .frame(height: Self.height, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .overlay(alignment: .topTrailing) {
            if status.canNudge {
                Button("Nudge") {
                    sendNudge(to: status.agent, model: model, terminals: terminals)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Tell it to pick up the next task")
                .padding(10)
            } else if status.canResume {
                Button("Start") {
                    Task { _ = await StartAgent.resume(agent: status.agent, model: model, terminals: terminals) }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Start it back up in the conversation it was having")
                .padding(10)
            }
        }
        .help("Show \(status.agent.label)")
        .contextMenu {
            if status.canResume {
                Button("Start \(status.agent.label)") {
                    Task { _ = await StartAgent.resume(agent: status.agent, model: model, terminals: terminals) }
                }
            }
            if status.canStop {
                Button("Stop \(status.agent.label)", role: .destructive) { model.stop(status.agent) }
            }
            Button("Delete \(status.agent.label)", role: .destructive) { model.delete(status.agent) }
        }
    }
}

struct AgentView: View {
    @Environment(AppModel.self) private var model
    @Environment(TerminalSessions.self) private var terminals
    var status: Dashboard.AgentStatus
    /// Back to the page this was opened from. Nil when there is nowhere to go.
    var back: (() -> Void)?
    @State private var showsDetails = true
    /// Stopping an agent cannot be taken back, and the header button is one click on a
    /// wide target, so it asks first. (T261.)
    @State private var confirmingStop = false
    @State private var resumeError: String?

    private struct ResourceLease: Identifiable {
        var resource: Resource
        var lease: Lease

        var id: UUID { lease.id }
    }

    private var agent: Agent { status.agent }
    private var leases: [ResourceLease] {
        model.snapshot.resources.flatMap { resource in
            model.snapshot.leases
                .filter { $0.resourceID == resource.id && $0.agentID == agent.id && $0.isActive(now: .now) }
                .map { ResourceLease(resource: resource, lease: $0) }
        }
    }

    /// The terminal is the page when there is one: it is what you came to watch, and it
    /// takes the height rather than sitting in a box inside a scroller. Everything about
    /// the agent goes beside it, in a column you can put away.
    /// (Alex, 13 Sep 2026: rethought.)
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session = terminals.session(for: agent) {
                HStack(spacing: 0) {
                    // The pane is the terminal it was made with: a representable hands
                    // its view over once and SwiftUI keeps it. Going from one agent to
                    // the next in the sidebar reuses this position, so without an
                    // identity of its own the pane went on showing the agent you came
                    // from. (Alex, 14 Sep 2026.) The identity is the run rather than the
                    // session, because starting a stopped agent back up makes a new
                    // terminal under the same session id and the page has to follow it.
                    // (Alex, 14 Sep 2026.)
                    TerminalPanel(terminal: session.terminal)
                        .id(session.run)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showsDetails {
                        Divider()
                        inspector.frame(width: 320)
                    }
                }
            } else {
                inspector.frame(maxWidth: 720, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: agent.id) { await reattach() }
        // Opening the page is the look it rang for, however you got here: from its card,
        // or from its row in the sidebar. (T225.)
        .onAppear { model.clearBell(agent) }
        .alert("It did not start", isPresented: Binding(get: { resumeError != nil }, set: { if !$0 { resumeError = nil } })) {
            Button("OK") { resumeError = nil }
        } message: {
            Text(resumeError ?? "")
        }
        .confirmationDialog("Stop \(agent.label)?", isPresented: $confirmingStop) {
            Button("Stop \(agent.label)", role: .destructive) { model.stop(agent) }
        } message: {
            Text("It stops in the middle of whatever it is doing. What it has already said stays here, and anything it was holding goes back.")
        }
        .toolbar {
            if let back {
                ToolbarItem(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left", action: back)
                        .help("Back to where you came from")
                }
            }
            ToolbarItem {
                Button("Details", systemImage: showsDetails ? "sidebar.right" : "sidebar.right") {
                    withAnimation(.snappy) { showsDetails.toggle() }
                }
                .help(showsDetails ? "Hide what is beside the terminal" : "Show what is beside the terminal")
            }
        }
    }

    /// Opening the page is the whole instruction. If this app has lost the terminal but
    /// tmux still holds it, take it back up now rather than asking with a button: you
    /// came here to watch the agent work, and an empty page with something to click
    /// first is a page that has not done its job.
    ///
    /// Finding out whether tmux still has it means running tmux, which waits, so that
    /// part happens off the main thread and the page stays live while it does. Nothing
    /// here ever blocks the window. (Alex, 13 Sep 2026: not at the price of a beachball.)
    private func reattach() async {
        guard terminals.session(for: agent) == nil else { return }
        let id = agent.id.uuidString
        await terminals.lookForHeldSessions()
        guard terminals.session(for: agent) == nil, terminals.isHeld(id) else { return }
        terminals.attach(id)
    }

    /// One line across the top: who it is, where, what it says it is doing, and when it
    /// last said anything. The
    /// dot says how it is doing, and says it in a word if you hold the pointer over it.
    /// (Alex, 13 Sep 2026: the word beside the dot said it twice.)
    private var header: some View {
        HStack(spacing: 10) {
            AgentActivityDot(activity: status.activity)
            Text(agent.label)
                .font(.title3.weight(.semibold))
            if status.activity == .stopped { StoppedMark() }
            AgentBellMark(ringing: agent.bel)
            if let project = status.project {
                Text(project.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // The line the agent set with its terminal title is what it is doing right
            // now, so it belongs on the top row beside the project rather than at the
            // top of a column you can put away. (Alex, 15 Sep 2026.)
            if !agent.title.isEmpty {
                Text(agent.title)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(agent.title)
            }
            Spacer(minLength: 12)
            if status.canNudge {
                Button("Nudge") {
                    sendNudge(to: agent, model: model, terminals: terminals)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Tell it to pick up the next task")
            }
            if status.canStop {
                Button("Stop") { confirmingStop = true }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("End this agent's process. What it has said stays on the page.")
            }
            // A stopped agent is picked back up where it left off, in the same session,
            // so it comes back knowing who it is and what it was doing. (T262.)
            if status.canResume {
                Button("Start") {
                    Task { resumeError = await StartAgent.resume(agent: agent, model: model, terminals: terminals) }
                }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .help("Start it back up in the conversation it was having")
            }
            Text(agent.lastSeen, format: .relative(presentation: .named))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// Everything that is not the terminal, in one scrolling column.
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                assignedTasks
                artifacts
                messages
                resources
                details
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var details: some View {
        AgentPanel("Details") {
            LabeledContent("Project", value: status.project?.name ?? "No project")
                .lineLimit(1)
            LabeledContent("Registered") {
                Text(agent.registered, format: .dateTime.month().day().hour().minute())
            }
            LabeledContent(agent.isConnected ? "Connected" : "Disconnected") {
                Text(agent.lastSeen, format: .relative(presentation: .named))
            }
        }
    }

    private var assignedTasks: some View {
        let tasks = model.tasks(assignedTo: agent.id)
        return AgentPanel("Assigned tasks") {
            if tasks.isEmpty {
                EmptyLine(text: agent.note.isEmpty ? "Nothing on it." : agent.note, symbol: "checklist")
            } else {
                ForEach(tasks) { task in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let label = task.label {
                            Text(label)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 34, alignment: .trailing)
                                .textSelection(.enabled)
                                .help("The task's number: say it, type it, or give it to an agent")
                        }
                        Text(task.title)
                        Spacer()
                        Text(task.state.word)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if task.id != tasks.last?.id { Divider() }
                }
            }
        }
    }

    private var artifacts: some View {
        let mine = Artifacts.produced(by: agent.id, in: model.snapshot.artifacts)
        return Group {
            if !mine.isEmpty {
                AgentPanel("Artifacts") {
                    ForEach(mine) { artifact in
                        ArtifactCard(artifact: artifact)
                        if artifact.id != mine.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var resources: some View {
        AgentPanel("Resources") {
            if leases.isEmpty {
                EmptyLine(text: "No resources are held.", symbol: "lock.rectangle.stack")
            } else {
                ForEach(leases) { held in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(held.resource.name)
                        Text(held.lease.why.isEmpty ? "Held until \(held.lease.until.formatted(date: .omitted, time: .shortened))" :
                             "\(held.lease.why) · until \(held.lease.until.formatted(date: .omitted, time: .shortened))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if held.id != leases.last?.id { Divider() }
                }
            }
        }
    }

    /// What has been sent to this agent, read newest last. There is no box to write in:
    /// a message is typed into the agent's terminal, so the way to say something to an
    /// agent is to say it in its terminal, which is on this page. (Alex, 14 Sep 2026.)
    private var messages: some View {
        AgentPanel("Messages") {
            AgentMessages(messages: model.messages(for: agent.id)) { model.delete($0) }
        }
    }
}

/// The page's one section shape: a heading, then its content on glass, same as the
/// cards on Capacity and the dashboard.
private struct AgentPanel<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        }
    }
}

/// The messages themselves, in the agent's page and in the row's popover alike.
private struct AgentMessages: View {
    var messages: [AgentMessage]
    /// Throwing one away. The inbox is a record of what was said to the agent, so the
    /// person clears it; nothing here reaches the agent twice. (Alex, 14 Sep 2026.)
    var delete: (AgentMessage) -> Void

    var body: some View {
        if messages.isEmpty {
            EmptyLine(text: "No messages yet.", symbol: "tray")
        } else {
            ForEach(messages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(message.subject)
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text(message.sent, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button("Delete", systemImage: "trash") { delete(message) }
                            .buttonStyle(.plain)
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Throw this message away")
                    }
                    Text("From \(message.from)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(message.contents)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button("Delete message", role: .destructive) { delete(message) }
                }
                if message.id != messages.last?.id { Divider() }
            }
        }
    }
}

/// Writes the nudge down and types it straight away, so the button acts at once rather
/// than on the next pass. The agent cannot tell the typed line from a person at the
/// keyboard.
@MainActor
func sendNudge(to agent: Agent, model: AppModel, terminals: TerminalSessions) {
    model.nudge(agent)
    deliverPendingMessages(model: model, terminals: terminals)
}

/// Types every message nobody has typed yet into its agent's terminal: nudges the person
/// sent, nudges `agent_nudge` asked for, and messages from other agents alike. One path,
/// because they are the same thing. A message is only marked delivered when a terminal
/// took it, so one sent to an agent with no window on screen waits instead of vanishing.
/// (T195, and Alex, 14 Sep 2026: messages are typed in, there is nothing to collect.)
@MainActor
func deliverPendingMessages(model: AppModel, terminals: TerminalSessions) {
    for agent in model.snapshot.agents {
        let waiting = model.undelivered(for: agent.id)
        guard !waiting.isEmpty else { continue }
        // Pick the session back up if this app has restarted since the agent was launched.
        // A terminal is only attached when somebody opens that agent's page, and a message
        // is meant to arrive while the agent is working, not whenever its page is next
        // looked at. tmux has been holding the session all along. (Alex, 14 Sep 2026.)
        terminals.attach(agent.id.uuidString)
        for message in waiting {
            guard terminals.sendLine(message.terminalLine, to: agent.id.uuidString) else { break }
            // Typed in is arrived, and an arrived message is not an inbox item any more.
            // (Alex, 14 Sep 2026: once it is sent, take it out of their inbox.)
            model.delete(message)
        }
    }
}

/// An agent, small: its dot and its name, in a capsule that opens the agent. Used
/// wherever a row has to say who is on something.
struct AgentChip: View {
    var status: Dashboard.AgentStatus
    /// A task in an agent's name that nobody has started reads as waiting, not working.
    var waiting = false
    var select: (UUID) -> Void

    var body: some View {
        Button { select(status.agent.id) } label: {
            HStack(spacing: 4) {
                if waiting {
                    Image(systemName: "person")
                } else {
                    AgentActivityDot(activity: status.activity)
                }
                Text(status.agent.label)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(waiting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(waiting ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.quaternary), in: .capsule)
        }
        .buttonStyle(.plain)
        .help(waiting ? "Waiting for \(status.agent.label): task_next hands it to them and nobody else"
                      : "\(status.agent.label) is on it")
    }
}

/// An agent whose process has gone, on a card or a page header. One symbol, and the
/// tooltip says what it means and what is still true: the terminal is there, the last
/// words are readable, the agent is not running. (Alex, 13 Sep 2026.)
struct StoppedMark: View {
    var body: some View {
        Image(systemName: "stop.circle")
            .foregroundStyle(.secondary)
            .help("Stopped: its terminal is still here and you can read what it said, but the agent is not running in it any more")
            .accessibilityLabel("Stopped")
    }
}

/// BEL from the agent's terminal: it wants a look. The bell is always there, quiet and
/// grey, so you know where to look for it; when the agent rings it fills in, turns orange
/// and wiggles until the page is opened. A mark that only exists while something is wrong
/// is a mark nobody learns to read. (Alex, 14 Sep 2026.)
struct AgentBellMark: View {
    var ringing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: ringing ? "bell.fill" : "bell")
            .foregroundStyle(ringing ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
            .symbolEffect(.wiggle, options: .repeating, isActive: ringing && !reduceMotion)
            .help(ringing ? "It rang for your attention" : "It has not rung")
            .accessibilityLabel(ringing ? "Wants a look" : "Quiet")
    }
}

struct AgentActivityDot: View {
    var activity: Dashboard.AgentActivity

    /// A stopped agent is drawn as a ring with nothing in it. It used to be red, which
    /// said something has gone wrong and wants you now; a stopped agent is inert, and it
    /// was shouting louder than a blocked one, which is the one that actually needs you.
    /// The quiet end of the palette was already taken, grey for waiting and ink for idle,
    /// so stopped is the absence of a fill rather than another shade: no process, no ink.
    /// It also survives colour blindness in a way grey against grey does not.
    /// (Alex, 14 Sep 2026.)
    var body: some View {
        Group {
            if activity == .stopped {
                Circle().strokeBorder(.tertiary, lineWidth: 1.5)
            } else {
                Circle().fill(Self.color(activity))
            }
        }
        .frame(width: 8, height: 8)
        .help(Self.help(activity))
    }

    static func color(_ activity: Dashboard.AgentActivity) -> Color {
        switch activity {
        case .working: .green
        case .blocked: .orange
        case .waiting: .gray
        case .idle: .primary
        case .stopped: .secondary
        }
    }

    static func help(_ activity: Dashboard.AgentActivity) -> String {
        switch activity {
        case .working: "Working"
        case .blocked: "Its task is blocked"
        case .waiting: "Waiting for a task, for mail, or for you"
        case .idle: "Idle: nothing said for ten minutes"
        case .stopped: "Stopped: its process has gone"
        }
    }
}

struct NotificationPrimer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Taktu: Software Factory can tell you when a question arrives, even with this window hidden. The banner carries the options, so you answer from it. Nothing leaves this Mac.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Continue") { model.askForNotifications() }
                .buttonStyle(.glassProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
