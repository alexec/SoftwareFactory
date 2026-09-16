import AppKit
import SwiftUI
import SoftwareFactoryKit

let lastLaunchAgentKey = "lastLaunchAgent"

/// The words the agent will start with, there to be read and changed before it goes.
/// They arrive as what the factory would have said, so launching without touching them
/// is exactly what launching used to do. The line naming the agent and its session is
/// not here: the factory writes that in front of whatever this says, because an agent
/// that does not know which session it is cannot use the factory at all. (T260.)
struct LaunchWords: View {
    @Binding var words: String
    var defaultWords: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("What it is told")
                    .font(.headline)
                Spacer()
                if words != defaultWords {
                    Button("Reset") { words = defaultWords }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(Color(.quiet))
                }
            }
            TextField("What this agent is for", text: $words, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.plain)
                .padding(8)
                .background(.quaternary, in: .rect(cornerRadius: Style.panel))
            Text("It is told its name and its session on top of this.")
                .font(.caption)
                .foregroundStyle(Color(.faint))
        }
    }
}

/// Pick which coding agent to start: a dropdown of the ones this factory can launch, the
/// words it will go with, then Launch <name>.
///
/// It was a segmented slider with a block of setup instructions under it, and both were
/// wrong for a screen you use all day. The slider spent the width on five names when one
/// is showing and four are a click away, and the instructions were read and dismissed on
/// every single launch although setting an agent up happens once. The instructions are in
/// the Help menu now and this links to them. (Alex, 16 Sep 2026.)
struct LaunchChooser<Extra: View>: View {
    var canLaunch: Bool
    var onLaunch: (LaunchAgent) -> Void
    var onCancel: (() -> Void)?
    var extra: Extra

    @State private var agent: LaunchAgent

    init(
        canLaunch: Bool = true,
        onLaunch: @escaping (LaunchAgent) -> Void,
        onCancel: (() -> Void)? = nil,
        @ViewBuilder extra: () -> Extra
    ) {
        self.canLaunch = canLaunch
        self.onLaunch = onLaunch
        self.onCancel = onCancel
        self.extra = extra()
        _agent = State(initialValue: LaunchAgent.remembered(UserDefaults.standard.string(forKey: lastLaunchAgentKey)))
    }

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker("Agent", selection: $agent) {
                    ForEach(LaunchAgent.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Agent")
                Spacer(minLength: 4)
                Button("Setting up agents", systemImage: "questionmark.circle") {
                    openWindow(id: AgentSetupHelp.windowID)
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .foregroundStyle(Color(.quiet))
                .help("How to install each agent and what to run once")
            }

            // Last thing before the button, because it is the last thing you decide and
            // it changes with the agent above it: pick what to start, see what it needs,
            // then read the words it will go with and press Launch. It used to sit at the
            // top, where you read it before you had chosen who was going to get it. (T273.)
            extra

            HStack {
                Spacer()
                if let onCancel {
                    Button("Cancel", action: onCancel)
                }
                Button(launchTitle) {
                    UserDefaults.standard.set(agent.rawValue, forKey: lastLaunchAgentKey)
                    onLaunch(agent)
                }
                    .buttonStyle(.glassProminent)
                    .disabled(!canLaunch)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private var launchTitle: String {
        if AgentLauncher.isSandboxed { return "Copy the command for \(agent.title)" }
        return "Launch \(agent.title)"
    }
}

extension LaunchChooser where Extra == EmptyView {
    init(
        canLaunch: Bool = true,
        onLaunch: @escaping (LaunchAgent) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.init(canLaunch: canLaunch, onLaunch: onLaunch, onCancel: onCancel) { EmptyView() }
    }
}
