import SwiftUI
import SoftwareFactoryKit

/// One project: who is on it and what they are on, its questions, and its backlog in order.
struct ProjectView: View {
    @Environment(AppModel.self) private var model
    var project: Project

    @State private var newTitle = ""
    @State private var showingMicPrimer = false

    private var tasks: [FactoryTask] { model.tasks(for: project.id) }
    private var questions: Escalations.Shown { Escalations.visible(for: project.id, in: model.snapshot.escalations) }

    var body: some View {
        List {
            Section {
                header
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

            if tasks.isEmpty {
                Section("Backlog") {
                    addRow
                    EmptyLine(text: "Nothing on the backlog.", symbol: "list.bullet")
                }
            }

            // One block per state. Only the backlog block reorders by drag; the three
            // newest done and ten newest parked are shown, the store keeps the rest. The
            // add row sits under the Backlog block, where a new task lands.
            ForEach(Backlog.blocks(tasks), id: \.state) { block in
                Section(block.state.word) {
                    if block.state == .backlog {
                        ForEach(block.tasks) { task in
                            TaskRow(task: task)
                        }
                        .onMove { source, destination in
                            model.move(in: project.id, from: source, to: destination)
                        }
                        addRow
                    } else {
                        ForEach(block.tasks) { task in
                            TaskRow(task: task)
                        }
                    }
                }
            }
            if !tasks.isEmpty, !tasks.contains(where: { $0.state == .backlog }) {
                Section("Backlog") { addRow }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var addRow: some View {
        Group {
                HStack(alignment: .top, spacing: 8) {
                    // Grows to five lines, so a dictated sentence can be read before it is added.
                    TextField("Add a task", text: $newTitle, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .onSubmit { add(at: .bottom) }
                    if model.dictation.isListening, !model.dictation.volatile.isEmpty {
                        Text(model.dictation.volatile)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Button {
                        toggleDictation()
                    } label: {
                        Image(systemName: model.dictation.isListening ? "stop.circle.fill" : "mic")
                            .foregroundStyle(model.dictation.isListening ? .red : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(model.dictation.isListening ? "Stop listening" : "Dictate a task")
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
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Add at the bottom; the arrow adds at the top")
                }
                .padding(.vertical, 4)
                .onChange(of: model.dictation.settled) { _, settled in
                    if model.dictation.isListening { newTitle = settled }
                }

                if showingMicPrimer, model.dictation.standing == .notAsked {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Software Factory listens while you dictate a task. The words are recognised on this Mac as you say them, and nothing is recorded.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Continue") {
                            _Concurrency.Task {
                                await model.dictation.ask()
                                showingMicPrimer = false
                                if model.dictation.standing == .allowed { await model.dictation.start() }
                            }
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    .listRowSeparator(.hidden)
                }
                if case .denied = model.dictation.standing {
                    Text("Dictation needs the microphone, which can be turned on for Software Factory in System Settings, Privacy and Security.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if case .unavailable(let why) = model.dictation.standing {
                    Text(why)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

        }
    }

    private var header: some View {
        let status = model.status(for: project.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ActivityDot(activity: status?.activity ?? .idle)
                Text(statusLine(status))
                    .font(.headline)
            }
            if let doing = status?.doing {
                Text(doing)
                    .foregroundStyle(.secondary)
            }
            if let status { ProgressNumbers(status: status) }
            Toggle("On hold", isOn: Binding(get: { project.onHold }, set: { model.setOnHold(project, $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Nothing is handed out from this backlog while it is on hold")
            Text(project.path)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private func statusLine(_ status: Dashboard.ProjectStatus?) -> String {
        if project.onHold { return "On hold" }
        guard let status, !status.agents.isEmpty else { return "Nobody is on it" }
        let names = status.agents.map(\.name).joined(separator: ", ")
        switch status.activity {
        case .working: return "\(names) \(status.agents.count == 1 ? "is" : "are") on it"
        case .waiting: return "\(names) \(status.agents.count == 1 ? "is" : "are") on it, waiting"
        case .idle: return "Nobody is on it"
        }
    }

    private func add(at position: Backlog.Position) {
        let text = newTitle
        newTitle = ""
        model.dictation.clear()
        _Concurrency.Task { await model.addTask(to: project.id, from: text, at: position) }
    }

    private func toggleDictation() {
        switch model.dictation.standing {
        case .notAsked:
            showingMicPrimer = true
        case .allowed:
            _Concurrency.Task {
                if model.dictation.isListening {
                    newTitle = await model.dictation.stop()
                } else {
                    await model.dictation.start()
                }
            }
        default:
            break
        }
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
                    .foregroundStyle(.green)
                Text(escalation.chosen?.title ?? "Decided")
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

/// How a project stands, as numbers in the colours the states use everywhere.
struct ProgressNumbers: View {
    var status: Dashboard.ProjectStatus
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 12) {
            number(status.blockedCount, "blocked", .orange)
            number(status.inProgressCount, "in progress", .green)
            number(status.backlogCount, "waiting", .secondary)
            number(status.doneCount, "done", .secondary.opacity(0.6))
        }
        .font(compact ? .caption.weight(.semibold) : .callout.weight(.medium))
        .monospacedDigit()
    }

    @ViewBuilder
    private func number(_ n: Int, _ word: String, _ color: Color) -> some View {
        if n > 0 || !compact {
            HStack(spacing: 3) {
                Text(n, format: .number).foregroundStyle(color)
                if !compact { Text(word).foregroundStyle(.secondary).font(.callout) }
            }
            .help("\(n) \(word)")
        }
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    var task: FactoryTask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.state == .done)
                    .foregroundStyle(task.state == .done || task.state == .parked ? .secondary : .primary)
                if task.state == .blocked, !task.blockers.isEmpty {
                    Text(task.blockedWhy)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let ending = task.note.split(whereSeparator: \.isNewline).last, !ending.isEmpty {
                    Text(ending)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if task.state == .inProgress {
                Text(model.agentName(task.agentID).map { "\($0) is on it" } ?? "in progress")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.2), in: .capsule)
            }
            if task.state == .blocked, let b = task.blocker {
                Text(task.blockers.count > 1 ? "Blocked on \(task.blockers.count) things" : "Blocked on \(word(for: b))")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: .capsule)
                    .help(b.why)
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
                } else if task.state != .done {
                    Button("Park") { model.set(task, to: .parked) }
                }
                if model.dashboard.projects.count > 1 {
                    Menu("Move to") {
                        ForEach(model.dashboard.projects.filter { $0.id != task.projectID }) { other in
                            Button(other.project.name) { model.moveTask(task, to: other.project) }
                        }
                    }
                }
                if task.state == .backlog {
                    Divider()
                    Button("Move to the top") { model.move(task, to: .top) }
                    Button("Move to the bottom") { model.move(task, to: .bottom) }
                }
                Divider()
                Button("Delete", role: .destructive) { model.delete(task) }
            } label: {
                Text(task.state.word)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private func word(for b: FactoryTask.Blocker) -> String {
        switch b.kind {
        case .person: "you: \(b.why)"
        case .decision: "your answer: \(b.why)"
        case .task: "another task: \(b.why)"
        case .other: b.why
        }
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
