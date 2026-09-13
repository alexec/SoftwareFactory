import SwiftUI
import SoftwareFactoryKit

/// One project's backlog on the phone: read it anywhere, add to it near the Mac.
struct PhoneBacklogView: View {
    @Environment(PhoneModel.self) private var model
    var project: Project

    @State private var newTitle = ""
    @State private var selectedTask: FactoryTask?
    @State private var editingTask: FactoryTask?

    private var tasks: [FactoryTask] { Backlog.visible(for: project.id, in: model.snapshot.tasks) }
    private var status: Dashboard.ProjectStatus? { model.dashboard.projects.first { $0.id == project.id } }
    private var questions: Escalations.Shown { Escalations.visible(for: project.id, in: model.snapshot.escalations) }

    var body: some View {
        List {
            Section {
                header
            }
            if !questions.open.isEmpty || !questions.decided.isEmpty {
                Section("Questions") {
                    ForEach(questions.open) { PhoneEscalationCard(escalation: $0) }
                    ForEach(questions.decided) { PhoneDecidedRow(escalation: $0) }
                }
            }
            if tasks.isEmpty {
                Section {
                    Label("Nothing on the backlog.", systemImage: "list.bullet")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Backlog.blocks(tasks), id: \.state) { block in
              Section(block.state.word) {
                ForEach(block.tasks) { task in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let label = task.label {
                                Text(label).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            Text(task.title)
                                .strikethrough(task.state == .done)
                                .foregroundStyle(task.state == .done || task.state == .parked ? .secondary : .primary)
                            Spacer()
                            Text(task.state == .inProgress ? "In progress" : (task.state == .done ? "Done" : (task.state == .parked ? "Parked" : "")))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(task.state == .inProgress ? .green : .secondary)
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
                            Text(task.blockedWhy).font(.caption).foregroundStyle(.orange).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(.rect)
                    .onTapGesture { selectedTask = task }
                }
              }
            }
            if model.source == .factory || model.cloud.isReady {
                Section("Add") {
                    HStack(alignment: .top, spacing: 8) {
                        TextField("Add a task", text: $newTitle, axis: .vertical)
                            .lineLimit(1...5)
                        Menu {
                            Button("Add to the top") { add(at: .top) }
                            Button("Add to the bottom") { add(at: .bottom) }
                        } label: {
                            Text("Add")
                        } primaryAction: {
                            add(at: .bottom)
                        }
                    }
                    .onSubmit { add(at: .bottom) }
                    if model.source != .factory {
                        Text("Away from the Mac; this goes through iCloud and lands there in a moment, numbered once it does.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Text("Adding a task needs iCloud, which is not signed in on this phone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedTask) { task in
            VStack(alignment: .leading, spacing: 12) {
                Text(task.title)
                    .font(.headline)
                    .strikethrough(task.state == .done)
                if let ending = task.note.split(whereSeparator: \.isNewline).last,
                   !ending.isEmpty,
                   ending != task.blockedWhy {
                    Text(ending)
                        .foregroundStyle(.secondary)
                }
                if task.state == .blocked, !task.blockers.isEmpty {
                    Text(task.blockedWhy)
                        .foregroundStyle(.orange)
                }
                Button("Edit") {
                    selectedTask = nil
                    editingTask = task
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding()
            .presentationDetents([.medium])
        }
        .sheet(item: $editingTask) { task in
            PhoneTaskEditor(task: task) { title, note in
                _Concurrency.Task { await model.editTask(task, title: title, note: note) }
            }
        }
    }

    private func add(at position: Backlog.Position) {
        let title = newTitle
        newTitle = ""
        _Concurrency.Task { await model.addTask(to: project, title: title, at: position) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(project.onHold ? Color.secondary.opacity(0.4)
                          : (status?.activity == .working ? Color.green
                             : (status?.activity == .waiting ? Color.orange : Color.secondary.opacity(0.4))))
                    .frame(width: 8, height: 8)
                Text(project.onHold ? "On hold" : (status?.doing ?? "Nobody is on it"))
                    .font(.headline)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PhoneTaskEditor: View {
    var task: FactoryTask
    var save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var note: String

    init(task: FactoryTask, save: @escaping (String, String) -> Void) {
        self.task = task
        self.save = save
        _title = State(initialValue: task.title)
        _note = State(initialValue: task.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Task", text: $title, axis: .vertical)
                    .lineLimit(1...4)
                TextField("Note", text: $note, axis: .vertical)
                    .lineLimit(3...8)
            }
            .navigationTitle("Edit task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(title, note)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// An answered question, folded to one line, on the phone. Open it to see the whole
/// card again. (Alex, 12 Sep 2026: the phone's project page gets its own Questions
/// section, matching the Mac's.)
struct PhoneDecidedRow: View {
    var escalation: Escalation
    @State private var isOpen = false

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            PhoneEscalationCard(escalation: escalation)
                .padding(.vertical, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(escalation.chosen?.title ?? escalation.decision?.note ?? "Decided")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(escalation.question)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
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
