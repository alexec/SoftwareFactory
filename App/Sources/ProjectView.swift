import SwiftUI
import SoftwareFactoryKit

/// One project: who is on it and what they are on, its questions, and its backlog in order.
struct ProjectView: View {
    @Environment(AppModel.self) private var model
    var project: Project

    @State private var newTitle = ""
    @State private var showingMicPrimer = false

    private var tasks: [FactoryTask] { model.tasks(for: project.id) }
    private var escalations: [Escalation] { model.escalations(for: project.id) }

    var body: some View {
        List {
            Section {
                header
            }

            if !escalations.isEmpty {
                Section("Questions") {
                    ForEach(escalations) { e in
                        EscalationCard(escalation: e, showsProject: false)
                            .listRowSeparator(.hidden)
                            .padding(.vertical, 4)
                    }
                }
            }

            Section("Backlog") {
                HStack(spacing: 8) {
                    TextField("Add a task", text: $newTitle)
                        .textFieldStyle(.plain)
                        .onSubmit(add)
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
                    Button("Add", action: add)
                        .buttonStyle(.glass)
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private func add() {
        model.addTask(to: project.id, title: newTitle, kind: .feature)
        newTitle = ""
        model.dictation.clear()
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

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    var task: FactoryTask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.state == .done)
                    .foregroundStyle(task.state == .done ? .secondary : .primary)
                if let ending = task.note.split(whereSeparator: \.isNewline).last, !ending.isEmpty {
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
            Spacer()
            Menu {
                ForEach(FactoryTask.State.allCases, id: \.self) { state in
                    Button(state.word) { model.set(task, to: state) }
                        .disabled(state == task.state)
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
}

extension FactoryTask.State {
    var word: String {
        switch self {
        case .backlog: "Backlog"
        case .inProgress: "In progress"
        case .done: "Done"
        }
    }
}
