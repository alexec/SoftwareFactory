import SwiftUI
import SoftwareFactoryKit

/// Every agent registered, one card each. Click one to open it.
struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(TerminalSessions.self) private var terminals
    var selectAgent: (UUID) -> Void = { _ in }

    @State private var writingPrompt = false
    @State private var prompt = ""
    @State private var launchError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                registeredAgents
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sessions started here that no agent has registered against yet.
    private var starting: [TerminalSessions.Session] {
        let claimed = Set(model.dashboard.agents.map(\.agent.id.uuidString))
        return terminals.starting(for: nil, claimed: claimed)
    }

    @ViewBuilder
    private var registeredAgents: some View {
        let agents = model.dashboard.agents
        VStack(alignment: .leading, spacing: 12) {
            Text("Agents")
                .font(.title2.weight(.semibold))
            if agents.isEmpty && starting.isEmpty {
                EmptyLine(text: "No agents yet. One appears here the moment it registers.", symbol: "person.2")
            }
            GlassEffectContainer(spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    ForEach(agents) { status in
                        AgentCard(status: status, select: selectAgent)
                    }
                    ForEach(starting) { session in
                        StartingAgentCard(started: session.started, ended: session.ended)
                    }
                    launchCard
                }
            }
        }
    }

    /// An agent on no project: a browser owner, a reviewer, anything that works across
    /// the factory. You say what it is; it starts in your home folder.
    private var launchCard: some View {
        Button { prompt = ""; writingPrompt = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                    Text(AgentLauncher.isSandboxed ? "Copy the launch command" : "Launch an agent")
                        .font(.headline)
                }
                Text("On no project. Say what it is for, in a line.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .frame(height: AgentCard.height, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .popover(isPresented: $writingPrompt, arrowEdge: .bottom) { promptSheet }
        .alert("The agent did not start", isPresented: Binding(get: { launchError != nil }, set: { if !$0 { launchError = nil } })) {
            Button("OK") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }

    private var promptSheet: some View {
        LaunchChooser(
            canLaunch: !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onLaunch: launch,
            onCancel: { writingPrompt = false }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("What is this agent for?")
                    .font(.headline)
                Text("It starts in your home folder, on no project, and hears from other agents in its terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("You're the browser owner. Agents send you messages when they want you to use Chrome for them.",
                          text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
            }
        }
    }

    private func launch(_ agent: LaunchAgent) {
        let words = prompt
        writingPrompt = false
        if Agents.atCap(model.snapshot.agents, cap: Agents.cap(model.throttle)) {
            launchError = Agents.fullMessage(cap: Agents.cap(model.throttle))
            return
        }
        guard let reserved = model.reserveAgent(for: nil) else {
            launchError = model.writeError ?? "The agent could not be written down."
            return
        }
        let session = reserved.id
        let name = reserved.label
        let command = { (prompt: String) in
            agent.command(for: LaunchPrompt.free(prompt, as: name, session: session), session: session)
        }
        guard !AgentLauncher.isSandboxed else {
            AgentLauncher.copyCommand(command(words))
            return
        }
        terminals.start(prompt: words, session: session.uuidString, agentID: reserved.id, command: command)
        model.findTheProcess(for: reserved)
    }
}
