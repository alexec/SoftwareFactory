import SwiftUI
import SoftwareFactoryKit

/// Every agent registered, one card each. Click one to open it.
struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(TerminalSessions.self) private var terminals
    var selectAgent: (UUID) -> Void = { _ in }

    @State private var writingPrompt = false
    @State private var prompt = ""

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
        let claimed = Set(model.dashboard.agents.compactMap(\.agent.session))
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
    }

    private var promptSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What is this agent for?")
                .font(.headline)
            Text("It starts in your home folder, on no project, and hears from other agents through its inbox.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("You're the browser owner. Agents send you messages when they want you to use Chrome for them.",
                      text: $prompt, axis: .vertical)
                .lineLimit(3...8)
            HStack {
                Spacer()
                Button("Cancel") { writingPrompt = false }
                Button("Launch", action: launch)
                    .buttonStyle(.glassProminent)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func launch() {
        let words = prompt
        writingPrompt = false
        let session = "sf-\(UUID().uuidString.prefix(8).lowercased())"
        let reserved = model.reserveAgent(for: nil, session: session)
        let name = reserved?.label ?? "an agent"
        let command = { (prompt: String) in
            model.preferredAgent.command(for: LaunchPrompt.free(prompt, as: name))
        }
        guard !AgentLauncher.isSandboxed else {
            AgentLauncher.copyCommand(command(words))
            return
        }
        terminals.start(prompt: words, session: session, agentID: reserved?.id, command: command)
    }
}
