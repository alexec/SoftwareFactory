import SwiftUI
import ForemanKit

/// One project: who is on it and what they are on, its questions, and its backlog in order.
struct ProjectView: View {
    @Environment(AppModel.self) private var model
    var project: Project

    @State private var newTitle = ""
    @State private var newKind: FactoryTask.Kind = .feature

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
                    Picker("Kind", selection: $newKind) {
                        ForEach(FactoryTask.Kind.allCases, id: \.self) { kind in
                            Label(kind.word, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("Add a task", text: $newTitle)
                        .textFieldStyle(.plain)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(.glass)
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.vertical, 4)

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
        model.addTask(to: project.id, title: newTitle, kind: newKind)
        newTitle = ""
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    var task: FactoryTask

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.kind.symbol)
                .foregroundStyle(task.kind == .bug ? .red : .secondary)
                .frame(width: 18)
                .help(task.kind.word)
            Text(task.title)
                .strikethrough(task.state == .done)
                .foregroundStyle(task.state == .done ? .secondary : .primary)
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
                Picker("Kind", selection: Binding(get: { task.kind }, set: { model.set(task, kind: $0) })) {
                    ForEach(FactoryTask.Kind.allCases, id: \.self) { Text($0.word).tag($0) }
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

extension FactoryTask.Kind {
    var word: String {
        switch self {
        case .feature: "Feature"
        case .bug: "Bug"
        case .chore: "Chore"
        }
    }

    var symbol: String {
        switch self {
        case .feature: "sparkles"
        case .bug: "ladybug"
        case .chore: "wrench.and.screwdriver"
        }
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
