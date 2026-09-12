import SwiftUI
import ForemanKit

/// One project: what it is on, its escalations, and its backlog in order.
struct ProjectView: View {
    @Environment(AppModel.self) private var model
    var project: Project

    @State private var newTitle = ""
    @State private var newKind: WorkItem.Kind = .feature

    private var items: [WorkItem] { model.items(for: project.id) }
    private var escalations: [Escalation] { model.escalations(for: project.id) }

    var body: some View {
        List {
            Section {
                header
            }

            if !escalations.isEmpty {
                Section("Escalations") {
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
                        ForEach(WorkItem.Kind.allCases, id: \.self) { kind in
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

                if items.isEmpty {
                    EmptyLine(text: "Nothing on the backlog.", symbol: "list.bullet")
                }

                ForEach(items) { item in
                    ItemRow(item: item)
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
        guard let status else { return "Idle" }
        switch status.activity {
        case .working:
            return status.liveSessions == 1 ? "An agent is working on it" : "\(status.liveSessions) agents are on it"
        case .waiting:
            return status.liveSessions == 1 ? "An agent is waiting" : "\(status.liveSessions) agents are waiting"
        case .idle:
            return "Nobody is on it"
        }
    }

    private func add() {
        model.addItem(to: project.id, title: newTitle, kind: newKind)
        newTitle = ""
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    var item: WorkItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(item.kind == .bug ? .red : .secondary)
                .frame(width: 18)
                .help(item.kind.word)
            Text(item.title)
                .strikethrough(item.state == .done)
                .foregroundStyle(item.state == .done ? .secondary : .primary)
            if item.state == .inProgress {
                Text(item.agent.map { "\($0) is on it" } ?? "in progress")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.2), in: .capsule)
            }
            Spacer()
            Menu {
                ForEach(WorkItem.State.allCases, id: \.self) { state in
                    Button(state.word) { model.set(item, to: state) }
                        .disabled(state == item.state)
                }
                Divider()
                Picker("Kind", selection: Binding(get: { item.kind }, set: { model.set(item, kind: $0) })) {
                    ForEach(WorkItem.Kind.allCases, id: \.self) { Text($0.word).tag($0) }
                }
                Divider()
                Button("Delete", role: .destructive) { model.delete(item) }
            } label: {
                Text(item.state.word)
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

extension WorkItem.Kind {
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

extension WorkItem.State {
    var word: String {
        switch self {
        case .backlog: "Backlog"
        case .inProgress: "In progress"
        case .done: "Done"
        }
    }
}
