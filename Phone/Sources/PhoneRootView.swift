import SwiftUI
import SoftwareFactoryKit

struct PhoneRootView: View {
    @Environment(PhoneModel.self) private var model
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !model.hasPrimedNetwork {
                        NetworkPrimer()
                    } else {
                        linkLine
                    }
                    needsYou
                    projects
                    onTheFloor
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Needs you")
            .navigationDestination(for: Project.self) { project in
                PhoneBacklogView(project: project)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
        }
        .sheet(isPresented: $showingSettings) { PhoneSettingsView() }
        .sheet(isPresented: Binding(get: { !model.hasSeenIntro }, set: { model.hasSeenIntro = !$0 })) {
            PhoneIntroSheet()
        }
    }

    @ViewBuilder
    private var linkLine: some View {
        switch model.link {
        case .notYetAsked, .looking:
            Label("Looking for the factory on this network.", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
                .font(.callout)
        case .connected(let name):
            Label("Connected to \(name).", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
        case .lost:
            if model.source == .cloud {
                Label("Away from the factory. Reading through iCloud.", systemImage: "icloud")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                Label("Lost the factory. It answers again when the Mac is awake and on this network, or through iCloud.", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var needsYou: some View {
        let open = model.dashboard.openEscalations
        if open.isEmpty {
            Label("Nothing needs you.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            ForEach(open) { escalation in
                PhoneEscalationCard(escalation: escalation)
            }
        }
    }

    @ViewBuilder
    private var projects: some View {
        let projects = model.dashboard.projects
        if !projects.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Projects")
                    .font(.title3.weight(.semibold))
                ForEach(projects) { status in
                    NavigationLink(value: status.project) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(status.activity == .working ? Color.green : (status.activity == .waiting ? Color.orange : Color.secondary.opacity(0.4)))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(status.project.name).font(.headline).foregroundStyle(status.project.onHold ? .secondary : .primary)
                                if status.project.onHold {
                                    Text("On hold").font(.subheadline).foregroundStyle(.secondary)
                                } else if let doing = status.doing {
                                    Text(doing).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                if status.blockedCount > 0 { Text(status.blockedCount, format: .number).foregroundStyle(.orange) }
                                if status.inProgressCount > 0 { Text(status.inProgressCount, format: .number).foregroundStyle(.green) }
                            }
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var onTheFloor: some View {
        let agents = model.dashboard.agents
        if !agents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("On the floor")
                    .font(.title3.weight(.semibold))
                ForEach(agents) { status in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(status.isWorking ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(status.agent.name).font(.headline)
                                if let project = status.project {
                                    Text(project.name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let line = status.task?.title ?? (status.agent.note.isEmpty ? nil : status.agent.note) {
                                Text(line).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

/// Shown once, in place, before the system's local network alert.
struct NetworkPrimer: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Software Factory looks for the factory running on your Mac, on the same Wi‑Fi, so you can answer its questions from here. Nothing leaves your network.")
                .fixedSize(horizontal: false, vertical: true)
            Button { model.startLooking() } label: {
                Text("Continue").frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct PhoneEscalationCard: View {
    @Environment(PhoneModel.self) private var model
    var escalation: Escalation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let project = model.project(for: escalation.projectID) {
                    Text(project.name)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: .capsule)
                }
                Text("\(escalation.raisedBy) · \(escalation.raised, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(escalation.question)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if !escalation.context.isEmpty {
                Text(escalation.context)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    ForEach(escalation.options) { option in
                        Button {
                            _Concurrency.Task { await model.decide(escalation, option) }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(option.title).font(.body.weight(.medium))
                                        if option.recommended {
                                            Text("Recommended")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(.tint.opacity(0.18), in: .capsule)
                                        }
                                    }
                                    if !option.detail.isEmpty {
                                        Text(option.detail)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
                    }
                }
            }
        }
        .padding(16)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 20))
    }
}
