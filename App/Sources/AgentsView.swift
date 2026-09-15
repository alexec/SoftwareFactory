import SwiftUI
import SoftwareFactoryKit

/// Every agent registered, one card each. Click one to open it.
struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(TerminalSessions.self) private var terminals
    var selectAgent: (UUID) -> Void = { _ in }


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
                    FreeAgentCard()
                }
            }
        }
    }

}
