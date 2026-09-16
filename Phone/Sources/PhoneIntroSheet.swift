import SwiftUI

/// Shown once on first launch, and again from "How it works" at the top of Settings.
struct PhoneIntroSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Taktu: Software Factory")
                            .font(Style.Text.welcome)
                        Text("The factory in your pocket. Agents on your Mac ask; you answer from wherever you are.")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How you use it")
                            .font(.headline)
                        step("Open it on the same Wi‑Fi as the Mac running Taktu: Software Factory. It finds the factory on its own.")
                        step("Read what needs you. Tap the option you choose.")
                        step("Open a project to add, rank and park work. The agent carries on.")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Why this one")
                            .font(.headline)
                        Text("One tap answers a question that would otherwise wait for you at the desk. Private and free forever.")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(Style.page)
            }
            Button {
                model.hasSeenIntro = true
                dismiss()
            } label: {
                Text("Open the factory").frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, Style.page)
            .padding(.bottom, 16)
        }
        .interactiveDismissDisabled()
    }

    private func step(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(Color(.quiet))
            Text(text)
        }
    }
}
