import AppKit
import SwiftUI
import ForemanKit

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                summary
                escalations
                projects
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
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
                StatTile(value: d.inProgress, label: "in progress", symbol: "hammer")
                StatTile(value: d.openEscalations.count, label: d.openEscalations.count == 1 ? "needs you" : "need you",
                         symbol: "questionmark.bubble", tint: d.openEscalations.isEmpty ? nil : .orange)
                StatTile(value: d.workingCount, label: "of \(d.projects.count) working", symbol: "person.2")
            }
        }
    }

    // MARK: Escalations

    @ViewBuilder
    private var escalations: some View {
        let open = model.dashboard.openEscalations
        VStack(alignment: .leading, spacing: 12) {
            Text("Needs you")
                .font(.title2.weight(.semibold))
            if open.isEmpty {
                EmptyLine(text: "Nothing needs you.", symbol: "checkmark.circle")
            } else {
                ForEach(open) { escalation in
                    EscalationCard(escalation: escalation, showsProject: true)
                }
            }
        }
    }

    // MARK: Projects

    @ViewBuilder
    private var projects: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projects")
                .font(.title2.weight(.semibold))
            if !model.claudeFolder.isGranted {
                ClaudeFolderPrimer()
            }
            if model.dashboard.projects.isEmpty {
                EmptyLine(text: "No projects yet.", symbol: "folder")
                Button("Add a project") { addProject() }
                    .buttonStyle(.glass)
            } else {
                VStack(spacing: 1) {
                    ForEach(model.dashboard.projects) { status in
                        ProjectRow(status: status)
                    }
                }
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
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

struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    var status: Dashboard.ProjectStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ActivityDot(activity: status.activity)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(status.project.name)
                        .font(.headline)
                    Text(activityWord)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if let doing = status.doing {
                    Text(doing)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            HStack(spacing: 14) {
                if status.openEscalations > 0 {
                    Label(status.openEscalations.formatted(), systemImage: "questionmark.bubble")
                        .foregroundStyle(.orange)
                }
                Label(status.backlogCount.formatted(), systemImage: "list.bullet")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .labelStyle(.titleAndIcon)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }

    private var activityWord: String {
        switch status.activity {
        case .working: "working"
        case .waiting: "waiting"
        case .idle: "idle"
        }
    }
}

/// Shown in place until the person points the app at Claude Code's folder.
struct ClaudeFolderPrimer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Foreman reads Claude Code's own session files to see which projects are being worked on and what each agent was last asked. It reads them from your .claude folder and sends nothing anywhere.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose the Claude folder") { model.claudeFolder.choose() }
                .buttonStyle(.glassProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
