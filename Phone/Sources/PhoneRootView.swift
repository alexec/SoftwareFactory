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
                        if model.notifier.standing == .notAsked {
                            NotificationPrimer()
                        }
                    }
                    // The floor before the backlog, the way the Mac's dashboard has it:
                    // questions first, then who is working, then where the work is. The
                    // agents were under a list of a dozen projects, which put the thing
                    // you open the phone to check at the bottom of the page.
                    // (Alex, 16 Sep 2026.)
                    needsYou
                    registeredAgents
                    projects
                }
                .padding(Style.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .background(Color(.paper))
            .navigationTitle("Needs you")
            .navigationDestination(for: Project.self) { project in
                PhoneBacklogView(project: project)
            }
            // By id rather than by the status: a status is a snapshot of a moment, and
            // the page it opens has to follow the agent as it works.
            .navigationDestination(for: UUID.self) { id in
                PhoneAgentView(agent: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
        }
        // The same paper and the same tint as the Mac. The two apps are one thing seen
        // from two places, so a card is the same corner and the ground is the same
        // ground. (Alex, 16 Sep 2026: harmonize the iPhone interface.)
        .tint(Color(.mark))
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
                .foregroundStyle(Color(.quiet))
                .font(.callout)
        case .connected(let name):
            Label("Connected to \(name).", systemImage: "checkmark.circle")
                .foregroundStyle(Color(.quiet))
                .font(.callout)
        case .lost:
            if model.source == .cloud {
                Label("Away from the factory. Reading through iCloud.", systemImage: "icloud")
                    .foregroundStyle(Color(.quiet))
                    .font(.callout)
            } else {
                Label("Lost the factory. It answers again when the Mac is awake and on this network, or through iCloud.", systemImage: "wifi.slash")
                    .foregroundStyle(Color(.quiet))
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var needsYou: some View {
        let open = model.dashboard.openEscalations
        if open.isEmpty {
            Label("Nothing needs you.", systemImage: "checkmark.circle")
                .foregroundStyle(Color(.quiet))
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
                    .font(.title2.weight(.semibold))
                ForEach(projects) { status in
                    NavigationLink(value: status.project) {
                        // The same row the Mac's sidebar draws: the name, how much is
                        // waiting on the backlog in grey, and a question waiting in
                        // orange. The dot and the counts of blocked and in progress came
                        // off the Mac in T358, because a row that reports on the work
                        // makes you read a dozen small numbers to find the one project you
                        // were looking for, and they should not have stayed here.
                        // (Alex, 16 Sep 2026.)
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(status.project.name)
                                    .font(.headline)
                                    .foregroundStyle(status.project.onHold ? Color(.quiet) : Color(.ink))
                                if status.project.onHold {
                                    Text("On hold").font(.subheadline).foregroundStyle(Color(.quiet))
                                }
                            }
                            Spacer(minLength: 4)
                            if status.backlogCount > 0 {
                                Text(status.backlogCount, format: .number)
                                    .font(.subheadline)
                                    .foregroundStyle(Color(.quiet))
                                    .monospacedDigit()
                            }
                            if status.openEscalations > 0 {
                                Text(status.openEscalations, format: .number)
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange.opacity(0.25), in: .capsule)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color(.faint))
                        }
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Green working, orange blocked, grey waiting, black idle: the Mac's colours.

    @ViewBuilder
    /// What an agent has in its name, or what it can say for itself. Off the same rule
    /// the Mac's sidebar uses.
    private func lines(for status: Dashboard.AgentStatus) -> [AgentLine.Line] {
        AgentLine.linesUnderTheName(
            tasks: Backlog.alreadyYours(status.agent.id, in: model.snapshot.tasks),
            report: status.agent.projectID.flatMap {
                Artifacts.statusReport(by: status.agent.id, on: $0, in: model.snapshot.artifacts)
            },
            title: status.agent.title)
    }

    @ViewBuilder
    private var registeredAgents: some View {
        let agents = model.dashboard.agents
        if !agents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("On the floor")
                    .font(.title2.weight(.semibold))
                ForEach(agents) { status in
                    NavigationLink(value: status.agent.id) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        AgentActivityDot(activity: status.activity)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(status.agent.label).font(.headline)
                                if status.agent.bel {
                                    Image(systemName: "bell.fill").foregroundStyle(.orange)
                                }
                                if let project = status.project {
                                    Text(project.name).font(.caption).foregroundStyle(Color(.quiet))
                                }
                            }
                            // The same lines the Mac's sidebar shows: every task in its
                            // name, and only failing that whatever it can say for
                            // itself. The raw terminal title was going straight on the
                            // row, so an agent that had run a long shell command put
                            // five lines of it on the page. (Alex, 16 Sep 2026.)
                            ForEach(lines(for: status)) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 5) {
                                    if let number = line.number {
                                        Text(number)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(Color(.faint))
                                    }
                                    Text(line.words)
                                        .font(.subheadline)
                                        .foregroundStyle(Color(.quiet))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Color(.faint))
                    }
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Shown once, in place, before the system's notification alert.
struct NotificationPrimer: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Taktu: Software Factory can tell you when a question arrives, wherever you are. The banner carries the options, so you answer from it. Questions travel through your own iCloud.")
                .fixedSize(horizontal: false, vertical: true)
            Button { model.askForNotifications() } label: {
                Text("Continue").frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
        }
        .padding(Style.cardPadding)
        .glassEffect(.regular, in: .rect(cornerRadius: Style.card))
    }
}

/// Shown once, in place, before the system's local network alert.
struct NetworkPrimer: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Taktu: Software Factory looks for the factory running on your Mac, on the same Wi‑Fi, so you can answer its questions from here. Nothing leaves your network.")
                .fixedSize(horizontal: false, vertical: true)
            Button { model.startLooking() } label: {
                Text("Continue").frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
        }
        .padding(Style.cardPadding)
        .glassEffect(.regular, in: .rect(cornerRadius: Style.card))
    }
}

struct PhoneEscalationCard: View {
    @Environment(PhoneModel.self) private var model
    var escalation: Escalation
    @State private var words = ""

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
                    .foregroundStyle(Color(.quiet))
                    .lineLimit(1)
            }
            Text(escalation.question)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if !escalation.context.isEmpty {
                Text(escalation.context)
                    .font(.subheadline)
                    .foregroundStyle(Color(.quiet))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let artifact = escalation.artifactID.flatMap({ id in model.snapshot.artifacts.first { $0.id == id } }) {
                ArtifactCard(artifact: artifact)
            } else if !escalation.link.isEmpty {
                ReviewLink(link: escalation.link)
            }
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    ForEach(escalation.options) { option in
                        Button {
                            let note = words
                            words = ""
                            _Concurrency.Task { await model.decide(escalation, option, note: note) }
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
                                            .foregroundStyle(Color(.quiet))
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
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Style.panel))
                    }
                }
            }
            // Typed before tapping an option it rides along as a note; sent on its own
            // it is the answer, none of the options.
            HStack(alignment: .bottom, spacing: 8) {
                TextField("A note for the agent, or your own answer", text: $words, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.subheadline)
                Button("Answer") {
                    let text = words
                    words = ""
                    _Concurrency.Task { await model.answer(escalation, text) }
                }
                .buttonStyle(.glass)
                .disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Style.panel))
        }
        .padding(Style.cardPadding)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: Style.card))
    }
}
