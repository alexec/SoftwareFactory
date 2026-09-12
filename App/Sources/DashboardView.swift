import AppKit
import SwiftUI
import SoftwareFactoryKit

/// The floor: what needs you, then who is on the floor.
struct FloorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                summary
                needsYou
                onTheFloor
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolbar {
            ToolbarItem {
                Button("Add a project", systemImage: "plus") { addProject() }
                    .help("Add a project folder")
            }
        }
    }

    // MARK: Summary

    private var summary: some View {
        let d = model.dashboard
        return GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                StatTile(value: d.inProgress, label: d.inProgress == 1 ? "task in progress" : "tasks in progress", symbol: "hammer")
                StatTile(value: d.openEscalations.count, label: d.openEscalations.count == 1 ? "needs you" : "need you",
                         symbol: "questionmark.bubble", tint: d.openEscalations.isEmpty ? nil : .orange)
                StatTile(value: d.agents.count, label: d.agents.count == 1 ? "agent on the floor" : "agents on the floor", symbol: "person.2")
            }
        }
        .frame(maxWidth: 900)
    }

    // MARK: Needs you

    @ViewBuilder
    private var needsYou: some View {
        let open = model.dashboard.openEscalations
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Needs you")
                    .font(.title2.weight(.semibold))
                if !open.isEmpty {
                    Text("Click an option and the agent is told.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if open.isEmpty {
                EmptyLine(text: "Nothing needs you.", symbol: "checkmark.circle")
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(open) { escalation in
                            EscalationCard(escalation: escalation, showsProject: true)
                                .frame(width: 380)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    // MARK: On the floor

    @ViewBuilder
    private var onTheFloor: some View {
        let agents = model.dashboard.agents
        VStack(alignment: .leading, spacing: 12) {
            Text("On the floor")
                .font(.title2.weight(.semibold))
            if agents.isEmpty {
                EmptyLine(text: "No agents yet. One appears here the moment it registers.", symbol: "person.2")
                if model.dashboard.projects.isEmpty {
                    Button("Add a project") { addProject() }
                        .buttonStyle(.glass)
                }
            } else {
                VStack(spacing: 1) {
                    ForEach(agents) { status in
                        AgentRow(status: status)
                    }
                }
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
                .frame(maxWidth: 900)
            }
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Choose the project's folder."
        if panel.runModal() == .OK, let url = panel.url {
            model.addProject(at: url)
        }
    }
}

struct StatTile: View {
    var value: Int
    var label: String
    var symbol: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(value, format: .number)
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .contentTransition(.numericText())
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassEffect(glass, in: .rect(cornerRadius: 18))
        .animation(.snappy, value: value)
    }

    private var glass: Glass {
        if let tint { return .regular.tint(tint.opacity(0.18)) }
        return .regular
    }
}

struct EmptyLine: View {
    var text: String
    var symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
            Text(text)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }
}

struct AgentRow: View {
    var status: Dashboard.AgentStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle()
                .fill(status.isWorking ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(status.agent.name)
                        .font(.headline)
                    if let project = status.project {
                        Text(project.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(status.waitingOnYou ? "waiting on you" : (status.isWorking ? "working" : "quiet"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.waitingOnYou ? .orange : .secondary)
                }
                if let line = status.task?.title ?? (status.agent.note.isEmpty ? nil : status.agent.note) {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(status.agent.lastSeen, format: .relative(presentation: .named))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
