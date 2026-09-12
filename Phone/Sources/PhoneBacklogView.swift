import SwiftUI
import SoftwareFactoryKit

/// One project's backlog on the phone: read it anywhere, add to it near the Mac.
struct PhoneBacklogView: View {
    @Environment(PhoneModel.self) private var model
    var project: Project

    @State private var newTitle = ""
    @State private var recording = false

    private var tasks: [FactoryTask] { Backlog.visible(for: project.id, in: model.snapshot.tasks) }

    var body: some View {
        List {
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
                            Text(task.state == .inProgress ? "In progress" : (task.state == .done ? "Done" : (task.state == .parked ? "Parked" : (task.state == .blocked ? "Blocked" : ""))))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(task.state == .inProgress ? .green : (task.state == .blocked ? .orange : .secondary))
                        }
                        if task.state == .blocked, !task.blockers.isEmpty {
                            Text(task.blockedWhy).font(.caption).foregroundStyle(.orange).lineLimit(2)
                        } else if let ending = task.note.split(whereSeparator: \.isNewline).last, !ending.isEmpty {
                            Text(ending)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
              }
            }
            if model.source == .factory {
                Section("Add") {
                    HStack(alignment: .top, spacing: 10) {
                        TextField("Add a task", text: $newTitle, axis: .vertical)
                            .lineLimit(1...5)
                            .onSubmit { add(at: .bottom) }
                        Button {
                            recording = true
                        } label: {
                            Image(systemName: "mic")
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dictate a task")
                        .sheet(isPresented: $recording) {
                            RecordOverlay(dictation: model.dictation) { words in
                                _Concurrency.Task { await model.addTask(to: project, title: words, at: .bottom) }
                            }
                            .presentationDetents([.medium])
                        }
                        Menu {
                            Button("Add to the top") { add(at: .top) }
                            Button("Add to the bottom") { add(at: .bottom) }
                        } label: {
                            Text("Add")
                        } primaryAction: {
                            add(at: .bottom)
                        }
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } else {
                Section {
                    Text("Adding a task needs the Mac's network for now. Reading works anywhere.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add(at position: Backlog.Position) {
        let title = newTitle
        newTitle = ""
        _Concurrency.Task { await model.addTask(to: project, title: title, at: position) }
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
