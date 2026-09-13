import SwiftUI

/// Shown once on first launch, and again from "How it works" at the top of Settings.
/// The words are Alex's. Three sections, one button.
struct IntroSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Taktu: Software Factory")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        Text("A factory where coding agents do the work and you make the calls.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("How you use it")
                            .font(.headline)
                        step("Register the factory's MCP server with your agent, once. Settings has the command.")
                        step("Agents check in, pick up tasks, and ask when they cannot decide.")
                        step("Answer a question by clicking one of the options the agent offered. The agent carries on.")
                        step("Keep each project's backlog in order: features, bugs and chores, top to bottom.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Why this one")
                            .font(.headline)
                        Text("Agents ask; you decide. The factory does not care what an agent runs on, and nothing leaves this Mac. Private and free forever.")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(28)
            }

            Button {
                model.hasSeenIntro = true
                dismiss()
            } label: {
                Text("Open the factory").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .frame(width: 440, height: 480)
    }

    private func step(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}
