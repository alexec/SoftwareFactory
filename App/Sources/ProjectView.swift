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

            Section("Backlog") {
                HStack(spacing: 8) {
                    TextField("Add a task", text: $newTitle)
                        .textFieldStyle(.plain)
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

                if tasks.isEmpty {
                    EmptyLine(text: "Nothing on the backlog.", symbol: "list.bullet")
                }

                ForEach(tasks) { task in
                    TaskRow(task: task)
                }
                .onMove { source, destination in
                    model.move(in: project.id, from: source, to: destination)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
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
            Text(project.path)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private func statusLine(_ status: Dashboard.ProjectStatus?) -> String {
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

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    var task: FactoryTask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.state == .done)
                    .foregroundStyle(task.state == .done || task.state == .parked ? .secondary : .primary)
                if task.state == .blocked, let why = task.blocker?.why {
                    Text(why)
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
                Text("Blocked on \(word(for: b))")
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
                if task.state == .parked || task.state == .blocked {
                    Button(task.state == .blocked ? "Unblock, back to the backlog" : "Back to the backlog") { model.set(task, to: .backlog) }
                } else if task.state != .done {
                    Button("Park") { model.set(task, to: .parked) }
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
        case .decision: "a decision: \(b.why)"
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
