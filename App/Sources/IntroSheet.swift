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
                        Text("Foreman")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        Text("Foreman shows what your coding agents are doing, and what they need from you.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("How you use it")
                            .font(.headline)
                        step("Point it at your Claude Code folder, once.")
                        step("Read the dashboard: which projects are being worked on, and on what.")
                        step("Answer an escalation by picking one of the options the agent offered.")
                        step("Keep each project's backlog in order: features, bugs and chores, top to bottom.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Why this one")
                            .font(.headline)
                        Text("Agents ask; you decide. Everything an agent needs from you sits in one place, so you answer once and get back to your day. Private and free forever.")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(28)
            }

            Button("Open the dashboard") {
                model.hasSeenIntro = true
                dismiss()
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .frame(width: 440, height: 460)
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
