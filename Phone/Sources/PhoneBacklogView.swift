import SwiftUI
import SoftwareFactoryKit

/// One project's backlog on the phone: read it anywhere, add to it near the Mac.
struct PhoneBacklogView: View {
    @Environment(PhoneModel.self) private var model
    var project: Project

    @State private var newTitle = ""
    @State private var showingMicPrimer = false

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
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
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
                    .onChange(of: model.dictation.settled) { _, settled in
                        if model.dictation.isListening { newTitle = settled }
                    }
                    if showingMicPrimer, model.dictation.standing == .notAsked {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Software Factory listens while you dictate a task. The words are recognised on this phone as you say them, and nothing is recorded.")
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                _Concurrency.Task {
                                    await model.dictation.ask()
                                    showingMicPrimer = false
                                    if model.dictation.standing == .allowed { await model.dictation.start() }
                                }
                            } label: {
                                Text("Continue").frame(maxWidth: .infinity, minHeight: 32)
                            }
                            .buttonStyle(.glassProminent)
                        }
                        .padding(.vertical, 6)
                    }
                    if case .denied = model.dictation.standing {
                        Text("Dictation needs the microphone, which can be turned on for Software Factory in the iOS Settings app.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if case .unavailable(let why) = model.dictation.standing {
                        Text(why).font(.callout).foregroundStyle(.secondary)
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
        model.dictation.clear()
        _Concurrency.Task { await model.addTask(to: project, title: title, at: position) }
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
