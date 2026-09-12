import SwiftUI
import SoftwareFactoryKit

/// One project: who is on it and what they are on, its questions, and its backlog in order.
struct ProjectView: View {
    @Environment(AppModel.self) private var model
    var project: Project

    @State private var newTitle = ""
    @State private var steer = ""

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

            Section {
                steering
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
                } else if !group.isEmpty || state == .parked {
                    Section(state.word) {
                        ForEach(group) { task in row(task, reorderable: state == .parked) }
                    }
                    .dropDestination(for: String.self) { ids, _ in
                        state == .parked ? drop(ids, atEndOf: .parked) : false
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
            TaskRow(task: task)
                .draggable(task.id.uuidString)
                .dropDestination(for: String.self) { ids, _ in drop(ids, above: task) }
        } else {
            TaskRow(task: task)
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
        DictateField(placeholder: "Add a task", text: $newTitle, dictation: model.dictation) {
            Menu {
                Button("Add to the top") { add(at: .top) }
                Button("Add to the bottom") { add(at: .bottom) }
                Button("Add to parked") { add(at: .parked) }
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

    // The top row: the dot, the name, the hold toggle, nothing else — no summary
    // numbers. (Alex, 12 Sep 2026.)
    private var header: some View {
        let status = model.status(for: project.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ActivityDot(activity: status?.activity ?? .idle)
                Text(project.name)
                    .font(.headline)
                Spacer()
                Toggle("Active", isOn: Binding(get: { !project.onHold }, set: { model.setOnHold(project, !$0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Off puts the project on hold: nothing is handed out from its backlog")
            }
            Text(project.onHold ? "On hold" : (status?.doing ?? "Nobody is on it"))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// A word for the agent. It waits here until the agent's next call about this
    /// project, then it is gone; until then it can be taken back. (Alex, 12 Sep 2026.)
    private var steering: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                TextField("A word for the agent, sent on its next call", text: $steer, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.callout)
                    .onSubmit(sendSteer)
                Button("Send", action: sendSteer)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(steer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("The agent reads it once, with its next reply from the factory")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
            ForEach(project.notes) { note in
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(.secondary)
                    Text(note.text)
                        .font(.callout)
                        .lineLimit(2)
                    Text("waiting for the agent")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Take back") { model.withdraw(note: note, from: project) }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
                .padding(.leading, 4)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func sendSteer() {
        model.note(steer, on: project)
        steer = ""
    }


    private func add(at position: Backlog.Position) {
        let text = newTitle
        newTitle = ""
        _Concurrency.Task { await model.addTask(to: project.id, from: text, at: position) }
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

/// How a project stands, as numbers in the colours the states use everywhere.
struct ProgressNumbers: View {
    var status: Dashboard.ProjectStatus
    var compact = false

    /// Compact (the sidebar): only blocked and in progress, and never a zero. Full (the
    /// project header): every count with its word, zeros left out. (Alex, 12 Sep 2026.)
    var body: some View {
        HStack(spacing: compact ? 6 : 12) {
            number(status.blockedCount, "blocked", .orange)
            number(status.inProgressCount, "in progress", .green)
            if !compact {
                number(status.backlogCount, "waiting", .secondary)
                number(status.doneCount, "done", .secondary.opacity(0.6))
            }
        }
        .font(compact ? .caption.weight(.semibold) : .callout.weight(.medium))
        .monospacedDigit()
    }

    @ViewBuilder
    private func number(_ n: Int, _ word: String, _ color: Color) -> some View {
        if n > 0 {
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
    @State private var commenting = false
    @State private var comment = ""

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
                Button("Add a comment…") { commenting = true }
                Button("Delete", role: .destructive) { model.delete(task) }
            } label: {
                Text(task.state.word)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .popover(isPresented: $commenting, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A comment goes on the task, signed and dated, for whoever picks it up.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Comment", text: $comment, axis: .vertical)
                        .lineLimit(2...8)
                        .onSubmit(addComment)
                    HStack {
                        Spacer()
                        Button("Cancel") { commenting = false }
                        Button("Add", action: addComment)
                            .buttonStyle(.glassProminent)
                            .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(16)
                .frame(width: 360)
            }
        }
        .padding(.vertical, 2)
    }

    private func addComment() {
        model.comment(on: task, comment)
        comment = ""
        commenting = false
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
