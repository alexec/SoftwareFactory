import AppKit
import SwiftUI
import SoftwareFactoryKit

let lastLaunchAgentKey = "lastLaunchAgent"

/// The help for one coding agent: how to install it, and the command that registers
/// this factory with it. Shown when launching, not as a setting.
struct AgentHelp: View {
    var agent: LaunchAgent
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let installURL = agent.installURL, let setup = agent.setupCommand {
                LabeledContent("How to install \(agent.title)") {
                    Link(installURL.absoluteString, destination: installURL)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Register the factory with it") {
                    Button(copied ? "Copied" : "Copy") {
                        AgentLauncher.copyCommand(setup)
                        copied = true
                    }
                }
                Text(setup)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: Style.panel))
            } else {
                // A terminal has nothing to install and nothing to register.
                Text("A shell in the project's folder, on the floor like any other, so you can run something by hand and watch it from the same page as the rest. Nothing is started in it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: agent) { _, _ in copied = false }
    }
}

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
                        .foregroundStyle(.secondary)
                }
            }
            TextField("What this agent is for", text: $words, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.plain)
                .padding(8)
                .background(.quaternary, in: .rect(cornerRadius: Style.panel))
            Text("It is told its name and its session on top of this.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Pick which coding agent to start. A segmented slider of the ones this factory
/// can launch, help for the one in view, then Launch <name>.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Agent", selection: $agent) {
                ForEach(LaunchAgent.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Agent")

            AgentHelp(agent: agent)

            // Last thing before the button, because it is the last thing you decide and
            // it changes with the agent above it: pick what to start, see what it needs,
            // then read the words it will go with and press Launch. It used to sit at the
            // top, where you read it before you had chosen who was going to get it.
            // Nothing is said to a shell, so the words are not offered for one. (T273.)
            if agent.isCodingAgent { extra }

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
        return agent.isCodingAgent ? "Launch \(agent.title)" : "Open a terminal"
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
