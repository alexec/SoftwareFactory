import SwiftUI
import SoftwareFactoryKit

/// One project's backlog on the phone: read it anywhere, add, rank and park.
struct PhoneBacklogView: View {
    @Environment(PhoneModel.self) private var model
    var project: Project

    @State private var newTitle = ""
    @State private var newParkedTitle = ""
    @State private var selectedTask: FactoryTask?
    @State private var editingTask: FactoryTask?
    @State private var showingAllDone = false

    private var canAdd: Bool { model.source == .factory || model.cloud.isReady }

    private var tasks: [FactoryTask] {
        Backlog.visible(for: project.id, in: model.snapshot.tasks, recentDone: showingAllDone ? Int.max : 3)
    }
    private var hiddenDone: Int {
        max(0, model.snapshot.tasks.filter { $0.projectID == project.id && $0.state == .done }.count - 3)
    }
    private var status: Dashboard.ProjectStatus? { model.dashboard.projects.first { $0.id == project.id } }
    private var questions: Escalations.Shown { Escalations.visible(for: project.id, in: model.snapshot.escalations) }
    private var artifacts: [Artifact] { Artifacts.live(for: project.id, in: model.snapshot.artifacts) }

    var body: some View {
        List {
            if project.onHold || (status?.isEmpty ?? true) {
                Section {
                    header
                }
            }
            if !questions.open.isEmpty || !questions.decided.isEmpty {
                Section("Questions") {
                    ForEach(questions.open) { EscalationCard(escalation: $0, model: model) }
                    ForEach(questions.decided) { PhoneDecidedRow(escalation: $0) }
                }
            }
            if !artifacts.isEmpty {
                Section("Artifacts") {
                    ForEach(artifacts) { ArtifactCard(artifact: $0) }
                }
            }
            ForEach([FactoryTask.State.blocked, .inProgress, .backlog, .parked, .done], id: \.self) { state in
                let group = tasks.filter { $0.state == state }
                if state == .backlog {
                    Section("Backlog") {
                        ForEach(group) { task in row(task) }
                            .onMove { source, dest in
                                move(group, from: source, to: dest, state: .backlog)
                            }
                        if canAdd { addRow }
                        else {
                            Text("Adding a task needs iCloud, which is not signed in on this phone.")
                                .font(.callout)
                                .foregroundStyle(Color(.quiet))
                        }
                    }
                } else if state == .parked {
                    Section("Parked") {
                        ForEach(group) { task in row(task) }
                            .onMove { source, dest in
                                move(group, from: source, to: dest, state: .parked)
                            }
                        if canAdd { parkedAddRow }
                    }
                } else if !group.isEmpty {
                    Section(state.word) {
                        ForEach(group) { task in row(task) }
                        if state == .done, hiddenDone > 0 {
                            Button(showingAllDone ? "Show less" : "Show more") {
                                showingAllDone.toggle()
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.paper))
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(item: $selectedTask) { task in
            VStack(alignment: .leading, spacing: 12) {
                Text(task.title)
                    .font(.headline)
                    .strikethrough(task.state == .done)
                if task.work != .implement && !task.work.isPrefix(of: task.title) {
                    Text(task.work.word)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color(.quiet))
                }
                if let ending = task.note.split(whereSeparator: \.isNewline).last,
                   !ending.isEmpty,
                   ending != task.blockedWhy {
                    Text(ending)
                        .foregroundStyle(Color(.quiet))
                }
                if task.state == .blocked, !task.blockers.isEmpty {
                    Text(task.blockedWhy)
                        .foregroundStyle(Color(.alarm))
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

    @ViewBuilder
    private func row(_ task: FactoryTask) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let label = task.label {
                    Text(label).font(.caption.monospacedDigit()).foregroundStyle(Color(.faint))
                }
                Text(task.title)
                    .strikethrough(task.state == .done)
                    .foregroundStyle(task.state == .done || task.state == .parked ? .secondary : .primary)
                if task.work != .implement && !task.work.isPrefix(of: task.title) {
                    Text(task.work.word)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color(.faint))
                }
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
                    .foregroundStyle(Color(.quiet))
                    .lineLimit(2)
            }
            if task.state == .blocked, !task.blockers.isEmpty {
                Text(task.blockedWhy).font(.caption).foregroundStyle(Color(.alarm)).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture { selectedTask = task }
        .swipeActions(edge: .trailing) {
            if task.state == .parked {
                Button("Back to the backlog") {
                    _Concurrency.Task { await model.set(task, to: .backlog) }
                }
                .tint(.blue)
            } else if task.state != .done {
                Button("Park") {
                    _Concurrency.Task { await model.set(task, to: .parked) }
                }
                .tint(Color(.alarm))
            }
        }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            }
            .onSubmit { add(at: .bottom) }
            if model.source != .factory {
                Text("Away from the Mac; this goes through iCloud and lands there in a moment, numbered once it does.")
                    .font(.caption)
                    .foregroundStyle(Color(.quiet))
            }
        }
    }

    private var parkedAddRow: some View {
        HStack(alignment: .top, spacing: 8) {
            WorkField(prompt: "Add a parked task", text: $newParkedTitle)
            Button("Add") { addParked() }
        }
        .onSubmit { addParked() }
    }

    private func add(at position: Backlog.Position) {
        let title = newTitle
        newTitle = ""
        _Concurrency.Task { await model.addTask(to: project, title: title, at: position) }
    }

    private func addParked() {
        let title = newParkedTitle
        newParkedTitle = ""
        _Concurrency.Task { await model.addTask(to: project, title: title, at: .parked) }
    }

    private func move(_ group: [FactoryTask], from source: IndexSet, to dest: Int, state: FactoryTask.State) {
        let ids = source.compactMap { group.indices.contains($0) ? group[$0].id : nil }
        _Concurrency.Task { await model.move(ids: ids, to: dest, state: state, projectID: project.id) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // The shared dot, so a project is the same colour here as on the Mac. This
                // row drew its own with two of the four colours in it, which is how a
                // vocabulary comes apart. (T423.)
                ActivityDot(activity: status?.activity ?? .finished,
                            isEmpty: status?.isEmpty ?? true,
                            onHold: project.onHold)
                if project.onHold {
                    Text("On hold")
                        .font(.headline)
                } else if status?.isEmpty ?? true {
                    Text("Nobody is on it")
                        .font(.headline)
                }
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
                WorkField(prompt: "Task", text: $title, lineLimit: 1...4)
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
    @Environment(PhoneModel.self) private var model
    var escalation: Escalation
    @State private var isOpen = false

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            EscalationCard(escalation: escalation, model: model)
                .padding(.vertical, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(.quiet))
                VStack(alignment: .leading, spacing: 2) {
                    Text(escalation.chosen?.title ?? escalation.decision?.note ?? "Decided")
                        .font(Style.Text.row.weight(.medium))
                        .lineLimit(1)
                    Text(escalation.question)
                        .font(.caption)
                        .foregroundStyle(Color(.quiet))
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
