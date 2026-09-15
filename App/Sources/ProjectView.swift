import AppKit
import SwiftUI
import SoftwareFactoryKit

/// One project: who is on it and what they are on, its questions, and its backlog in order.
struct ProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(TerminalSessions.self) private var terminals
    @Environment(Floor.self) private var floor
    var project: Project
    var selectAgent: (UUID) -> Void = { _ in }

    @State private var newTitle = ""
    @State private var newParkedTitle = ""
    @State private var launchError: String?
    @State private var showingAllDone = false


    private var tasks: [FactoryTask] {
        Backlog.visible(for: project.id, in: model.snapshot.tasks, recentDone: showingAllDone ? Int.max : 3)
    }
    private var hiddenDone: Int {
        max(0, model.snapshot.tasks.filter { $0.projectID == project.id && $0.state == .done }.count - 3)
    }
    private var questions: Escalations.Shown { Escalations.visible(for: project.id, in: model.snapshot.escalations) }
    /// How wide the documents are here, remembered across launches. Its own setting
    /// rather than the agent page's: what a backlog needs beside it is not what a
    /// terminal needs. (T349.)
    @AppStorage("projectDocumentsWidth") private var documentsWidth = 420.0
    @State private var showsDocuments = true
    private var artifacts: [Artifact] { Artifacts.live(for: project.id, in: model.snapshot.artifacts) }

    /// The project and its documents side by side, which with the sidebar is three
    /// columns. The documents were a section inside the backlog, so reading one meant
    /// scrolling past the work to get to it and losing your place in the work to read
    /// it. They are reading matter and the backlog is a list; they do not belong in the
    /// same scroller. (T349, Alex, 15 Sep 2026.)
    var body: some View {
        GeometryReader { page in
            HStack(spacing: 0) {
                backlog
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !artifacts.isEmpty && showsDocuments {
                    ColumnGrip(width: $documentsWidth, beside: page.size.width)
                    ArtifactBrowser(documents: artifacts) { model.delete($0) }
                        // A different project is a different pile: start on its newest
                        // rather than carrying the last project's choice across.
                        .id(project.id)
                        .frame(width: ColumnGrip.width(documentsWidth, beside: page.size.width))
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Documents", systemImage: "doc.richtext") {
                    withAnimation(.snappy) { showsDocuments.toggle() }
                }
                .disabled(artifacts.isEmpty)
                .help(artifacts.isEmpty
                      ? "Nothing has been filed on this project yet"
                      : (showsDocuments ? "Hide the documents" : "Show the documents"))
            }
        }
    }

    private var backlog: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            // The same cards as the Agents page, filtered to this project.
            Section("Agents") {
                agents
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if !questions.open.isEmpty || !questions.decided.isEmpty {
                Section("Questions") {
                    ForEach(questions.open) { e in
                        EscalationCard(escalation: e, showsProject: false)
                            .listRowSeparator(.hidden)
                            .padding(.vertical, 4)
                    }
                    ForEach(questions.decided) { e in
                        DecidedRow(escalation: e)
                    }
                }
            }

            // One section per state, in a fixed order, so the Backlog section (with the
            // add row under it, where a new task lands) is always in the same place.
            // Backlog and Parked rows are draggable, onto each other (crossing the line
            // moves the row) and onto their own section (reordering it); dragging past
            // the last row of a section, or into an empty one, lands at its bottom.
            ForEach([FactoryTask.State.blocked, .inProgress, .backlog, .parked, .done], id: \.self) { state in
                let group = tasks.filter { $0.state == state }
                if state == .backlog {
                    Section("Backlog") {
                        ForEach(group) { task in row(task, reorderable: true) }
                        addRow
                    }
                    .dropDestination(for: String.self) { ids, _ in drop(ids, atEndOf: .backlog) }
                } else if state == .parked {
                    Section("Parked") {
                        ForEach(group) { task in row(task, reorderable: true) }
                        parkedAddRow
                    }
                    .dropDestination(for: String.self) { ids, _ in drop(ids, atEndOf: .parked) }
                } else if !group.isEmpty {
                    Section(state.word) {
                        ForEach(group) { task in row(task, reorderable: false) }
                        if state == .done, hiddenDone > 0 {
                            Button(showingAllDone ? "Show less" : "Show more") {
                                showingAllDone.toggle()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(_ task: FactoryTask, reorderable: Bool) -> some View {
        if reorderable {
            TaskRow(task: task, selectAgent: selectAgent)
                .draggable(task.id.uuidString)
                .dropDestination(for: String.self) { ids, _ in drop(ids, above: task) }
        } else {
            TaskRow(task: task, selectAgent: selectAgent)
        }
    }

    /// A row dragged onto another lands directly above it, in that row's section;
    /// crossing from the backlog to parked, or back, moves it there too.
    @discardableResult
    private func drop(_ ids: [String], above target: FactoryTask) -> Bool {
        var moved = false
        for id in ids {
            guard let uuid = UUID(uuidString: id), let dragged = tasks.first(where: { $0.id == uuid }), dragged.id != target.id
            else { continue }
            model.place(dragged, above: target)
            moved = true
        }
        return moved
    }

    /// A row dragged past the last one of a section, or into an empty one, lands at
    /// its bottom, same as its row menu's Park or Back to the backlog.
    @discardableResult
    private func drop(_ ids: [String], atEndOf state: FactoryTask.State) -> Bool {
        var moved = false
        for id in ids {
            guard let uuid = UUID(uuidString: id), let task = tasks.first(where: { $0.id == uuid }), task.state != state
            else { continue }
            model.set(task, to: state)
            moved = true
        }
        return moved
    }

    private var addRow: some View {
        HStack(alignment: .top, spacing: 8) {
            WorkField(prompt: "Add a task", text: $newTitle)
            Menu {
                Button("Add to the top") { add(at: .top) }
                Button("Add to the bottom") { add(at: .bottom) }
            } label: {
                Text("Add")
            } primaryAction: {
                add(at: .bottom)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            .help("Add at the bottom; the arrow adds at the top")
        }
        .onSubmit { add(at: .bottom) }
        .padding(.vertical, 4)
    }

    /// Straight into Parked, never through the backlog or task_next, same as the
    /// backlog's own add row lands there. (Alex, 12 Sep 2026.)
    private var parkedAddRow: some View {
        HStack(alignment: .top, spacing: 8) {
            WorkField(prompt: "Add a parked task", text: $newParkedTitle)
            Button("Add") { addParked() }
                .buttonStyle(.glassProminent)
                .fixedSize()
        }
        .onSubmit { addParked() }
        .padding(.vertical, 4)
    }

    // The top row: the dot, the name, the hold toggle, nothing else — no summary
    // numbers. (Alex, 12 Sep 2026.) Editing happens in a popover, so the backlog
    // underneath never jumps.

    private var header: some View {
        let status = model.status(for: project.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ActivityDot(activity: status?.activity ?? .idle, isEmpty: status?.isEmpty ?? true, onHold: project.onHold)
                Text(project.name)
                    .font(.title3.weight(.semibold))
                if project.onHold {
                    Text("on hold")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Active", isOn: Binding(get: { !project.onHold }, set: { model.setOnHold(project, !$0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Off puts the project on hold: its agents are stopped and nothing is handed out from its backlog")
            }
            // Where it lives. Who is on it, and starting another, are the cards below.
            HStack(spacing: 10) {
                // The path opens the folder, because that is what clicking a path means
                // anywhere else; changing it is the rarer thing and says so. A project
                // with no folder yet has the one button, which sets it. (T300.)
                if let url = OpenFolder.url(for: project) {
                    Button(pathDisplay) { OpenFolder.open(url) }
                        .buttonStyle(.borderless)
                        .help("Show \(pathDisplay) in the Finder")
                    Button("Change…") { chooseFolder() }
                        .buttonStyle(.borderless)
                        .help("Choose a different folder for an agent to run in")
                } else {
                    Button(pathDisplay) { chooseFolder() }
                        .buttonStyle(.borderless)
                        .help("Set the folder an agent should run in")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Style.card))
        .alert("The agent did not start", isPresented: Binding(get: { launchError != nil }, set: { if !$0 { launchError = nil } })) {
            Button("OK") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }

    /// Sessions started here that no agent has registered against yet.
    private var starting: [TerminalSessions.Session] {
        let claimed = Set(model.dashboard.agents.map(\.agent.id.uuidString))
        return terminals.starting(for: project.id, claimed: claimed)
    }

    private var agents: some View {
        let onIt = model.dashboard.agents.filter { $0.project?.id == project.id }
        // The last card in the grid starts another one, so it sits with the agents it
        // is about rather than up in the header.
        return GlassEffectContainer(spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                ForEach(onIt) { status in
                    AgentCard(status: status, select: selectAgent)
                }
                ForEach(starting) { session in
                    StartingAgentCard(started: session.started, ended: session.ended)
                }
                LaunchAgentCard(
                    title: AgentLauncher.isSandboxed ? "Copy the launch command" : "Launch an agent",
                    detail: AgentLauncher.isSandboxed ? "The command goes on the clipboard." : model.launchStyle.detail,
                    help: launchHelp,
                    isReady: project.path != nil,
                    defaultWords: LaunchPrompt.projectWork(project),
                    launch: { launchAgent($0, agent: $1, words: $2) })
            }
        }
    }

    private var launchHelp: String {
        if project.path == nil { return "Set the project folder before launching an agent" }
        if AgentLauncher.isSandboxed {
            return "This build is sandboxed, so an agent it started could not reach your own environment. The command goes on the clipboard instead."
        }
        return "Claude Code, GitHub Copilot or Grok, in the project's folder."
    }

    /// In the app, where its page shows it working and you can type to it, or in
    /// Terminal, where it outlives the app.
    private func launchAgent(_ style: AppModel.LaunchStyle, agent: LaunchAgent, words: String) {
        // The agent is written down first, so it has a name before it starts and the
        // card, the transcript and the prompt all say the same thing.
        Task {
            launchError = await StartAgent.run(project: project, agent: agent, style: style, model: model,
                                               terminals: terminals, floor: floor, words: words)
        }
    }

    private var pathDisplay: String {
        guard let path = project.path, !path.isEmpty else { return "Set the project folder..." }
        return Projects.shortPath(path)
    }

    /// Runs the panel there and then. `begin` handed the choice back on a callback the
    /// window sometimes outlived, and the folder never landed. (Alex, 12 Sep 2026.)
    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder where this project lives."
        if let path = project.path, !path.isEmpty {
            panel.directoryURL = URL(filePath: path)
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func chooseFolder() {
        guard let url = pickFolder() else { return }
        model.setPath(project, url.path)
    }

    private func add(at position: Backlog.Position) {
        let text = newTitle
        newTitle = ""
        _Concurrency.Task { await model.addTask(to: project.id, from: text, at: position) }
    }

    private func addParked() {
        let text = newParkedTitle
        newParkedTitle = ""
        _Concurrency.Task { await model.addTask(to: project.id, from: text, at: .parked) }
    }
}

/// A session that has started but whose agent has not registered yet: a card with the
/// shape of the one that is coming. A session whose shell has exited says so instead.
struct StartingAgentCard: View {
    var started: Date
    var ended: Date?
    @State private var faded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.tertiary)
                    .frame(width: 8, height: 8)
                Text(ended == nil ? "Starting" : "Ended")
                    .font(.headline)
                Spacer(minLength: 0)
                if ended == nil {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(ended == nil ? "Waiting for it to register." : "It stopped before registering.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .frame(height: AgentCard.height, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: Style.card))
        .opacity(faded && ended == nil ? 0.5 : 1)
        .animation(ended == nil ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default, value: faded)
        .onAppear { faded = true }
        .help("Started \(started.formatted(date: .omitted, time: .shortened)). It becomes a card of its own when it registers.")
    }
}

/// The card that starts another agent on this project, shaped like the agents beside it.
private struct LaunchAgentCard: View {
    @Environment(AppModel.self) private var model
    var title: String
    var detail: String
    var help: String
    var isReady: Bool
    /// The words the factory would use, which the person may edit before launching.
    var defaultWords: String
    var launch: (AppModel.LaunchStyle, LaunchAgent, String) -> Void

    @State private var choosing = false
    @State private var styleForThisLaunch: AppModel.LaunchStyle?
    @State private var words = ""

    var body: some View {
        Button { choosing = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                    Text(title)
                        .font(.headline)
                }
                Text(isReady ? detail : "Set the project's folder first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .frame(height: AgentCard.height, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .foregroundStyle(isReady ? .primary : .tertiary)
        .glassEffect(.regular, in: .rect(cornerRadius: Style.card))
        .help(help)
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            LaunchChooser(onLaunch: start, onCancel: { choosing = false }) {
                LaunchWords(words: $words, defaultWords: defaultWords)
            }
        }
        .onChange(of: choosing) { _, open in if open { words = defaultWords } }
        // Either way, whichever the settings say by default, then pick the agent.
        .contextMenu {
            ForEach(AppModel.LaunchStyle.allCases) { style in
                Button(style.title) {
                    styleForThisLaunch = style
                    choosing = true
                }
            }
        }
    }

    private func start(_ agent: LaunchAgent) {
        choosing = false
        let style = styleForThisLaunch ?? model.launchStyle
        styleForThisLaunch = nil
        launch(style, agent, words)
    }
}

/// An answered question, folded to one line. Open it to see the whole card again.
struct DecidedRow: View {
    var escalation: Escalation
    @State private var isOpen = false

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            EscalationCard(escalation: escalation, showsProject: false)
                .padding(.vertical, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Text(escalation.chosen?.title ?? escalation.decision?.note ?? "Decided")
                    .lineLimit(1)
                    .font(.callout.weight(.medium))
                Text(escalation.question)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let at = escalation.decision?.at {
                    Text(at, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}


struct TaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(TerminalSessions.self) private var terminals
    @Environment(Floor.self) private var floor
    var task: FactoryTask
    var selectAgent: (UUID) -> Void = { _ in }
    @State private var launchError: String?
    @State private var editing = false
    @State private var title = ""
    @State private var note = ""
    @State private var showingText = false
    @State private var choosingAgent = false
    /// The words this agent will start with, editable before it goes. (T260.)
    @State private var words = ""

    /// The agent on it, as the factory knows it.
    private var onIt: Dashboard.AgentStatus? {
        task.agentID.flatMap { id in model.dashboard.agents.first { $0.id == id } }
    }

    /// Agents on this task's project, to put it in the name of one.
    private var registeredAgents: [Dashboard.AgentStatus] {
        model.dashboard.agents.filter { $0.project?.id == task.projectID }
    }

    /// The project this task is on: an agent started for it runs in that folder.
    private var project: Project? { model.project(for: task.projectID) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let label = task.label {
                Text(label)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 34, alignment: .trailing)
                    .textSelection(.enabled)
                    .help("The task's number: say it, type it, or give it to an agent")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.state == .done)
                    .foregroundStyle(task.state == .done || task.state == .parked ? .secondary : .primary)
                if task.work != .implement && !task.work.isPrefix(of: task.title) {
                    Text(task.work.word)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .help(task.work.brief)
                }
                if let ending = task.note.split(whereSeparator: \.isNewline).last,
                   !ending.isEmpty,
                   ending != task.blockedWhy {
                    Text(ending)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if task.state == .blocked, !task.blockers.isEmpty {
                    Text(task.blockedWhy)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            .contentShape(.rect)
            .onTapGesture(count: 2) {
                showingText = false
                beginEditing()
            }
            .onTapGesture {
                guard !editing else { return }
                showingText = true
            }
            .help("Double-click to edit")
            .popover(isPresented: $showingText) {
                taskText
            }
            // Who is on it, or whose it is once assigned.
            if let agent = onIt, task.state == .backlog || task.state == .inProgress {
                AgentChip(status: agent, waiting: task.state == .backlog, select: selectAgent)
            }
            Spacer()
            // The person's menu: park, unpark, move, delete. Whether a task is in
            // progress or done is the agent's to say, so those are not here.
            Menu {
                if task.state == .blocked {
                    ForEach(Array(task.blockers.enumerated()), id: \.offset) { _, b in
                        Button("Clear: \(b.why)") { model.unblock(task, b) }
                    }
                    Button("Unblock, back to the backlog") { model.set(task, to: .backlog) }
                } else if task.state == .parked {
                    Button("Back to the backlog") { model.set(task, to: .backlog) }
                } else if task.state == .inProgress {
                    // For an agent that gave up, went quiet, or was never coming back.
                    Button("Take it back to the backlog") { model.takeBack(task) }
                    Button("Park") { model.set(task, to: .parked) }
                } else if task.state != .done {
                    Button("Park") { model.set(task, to: .parked) }
                }
                // Whose it is. An assigned task is handed to that agent by task_next and
                // passed over by everyone else.
                if task.state == .backlog {
                    Menu("Assign to") {
                        ForEach(registeredAgents) { status in
                            Button(status.agent.label) { model.assign(task, to: status.agent) }
                        }
                        if task.agentID != nil {
                            Divider()
                            Button("Nobody") { model.assign(task, to: nil) }
                        }
                    }
                    .disabled(registeredAgents.isEmpty && task.agentID == nil)
                    // A new agent, started on this one task: the task goes into its name
                    // and it is told to claim it.
                    Button(AgentLauncher.isSandboxed ? "Copy the command for this task" : "Start an agent on this") {
                        choosingAgent = true
                    }
                    .disabled(project?.path == nil)
                    .help(launchHelp)
                }
                if task.state == .backlog {
                    Divider()
                    Button("Move to the top") { model.move(task, to: .top) }
                    Button("Move to the bottom") { model.move(task, to: .bottom) }
                }
                Divider()
                Button("Edit…", action: beginEditing)
                Button("Delete", role: .destructive) { model.delete(task) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Task")
            .popover(isPresented: $editing, arrowEdge: .trailing) {
                editTask
            }
            .popover(isPresented: $choosingAgent, arrowEdge: .trailing) {
                LaunchChooser(onLaunch: launchAgent, onCancel: { choosingAgent = false }) {
                    LaunchWords(words: $words, defaultWords: defaultWords)
                }
            }
            .onChange(of: choosingAgent) { _, open in if open { words = defaultWords } }
        }
        .padding(.vertical, 2)
        .alert("The agent did not start", isPresented: Binding(get: { launchError != nil }, set: { if !$0 { launchError = nil } })) {
            Button("OK") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }

    private var launchHelp: String {
        if project?.path == nil { return "Set the project folder before starting an agent" }
        if AgentLauncher.isSandboxed {
            return "This build is sandboxed, so an agent it started could not reach your own environment. The command goes on the clipboard instead."
        }
        return "Claude Code, GitHub Copilot or Grok, with this task in its name."
    }

    /// A new agent for this one task. It is written down, the task goes into its name,
    /// and the words it starts with say which task to claim.
    private func launchAgent(_ agent: LaunchAgent) {
        choosingAgent = false
        guard let project else { return }
        Task {
            launchError = await StartAgent.run(project: project, task: task, agent: agent,
                                               style: model.launchStyle, model: model,
                                               terminals: terminals, floor: floor, words: words)
        }
    }

    /// What this agent would be told if nobody touched it: the task, and what to produce.
    private var defaultWords: String {
        guard let project else { return "" }
        return LaunchPrompt.taskWork(task, in: project)
    }

    private func beginEditing() {
        title = task.title
        note = task.note
        editing = true
    }

    private func saveEdit() {
        model.edit(task, title: title, note: note)
        editing = false
    }

    private var editTask: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit task")
                .font(.headline)
            WorkField(prompt: "Task", text: $title, lineLimit: 1...4)
            TextField("Note", text: $note, axis: .vertical)
                .lineLimit(3...8)
            HStack {
                Spacer()
                Button("Cancel") { editing = false }
                Button("Save", action: saveEdit)
                    .buttonStyle(.glassProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var taskText: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(task.title)
                .font(.headline)
                .strikethrough(task.state == .done)
                .fixedSize(horizontal: false, vertical: true)
            if task.work != .implement && !task.work.isPrefix(of: task.title) {
                Text(task.work.word)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .help(task.work.brief)
            }
            if let ending = task.note.split(whereSeparator: \.isNewline).last,
               !ending.isEmpty,
               ending != task.blockedWhy {
                Text(ending)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if task.state == .blocked, !task.blockers.isEmpty {
                Text(task.blockedWhy)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

}

extension FactoryTask.State {
    var word: String {
        switch self {
        case .backlog: "Backlog"
        case .inProgress: "In progress"
        case .done: "Done"
        case .parked: "Parked"
        case .blocked: "Blocked"
        }
    }
}
