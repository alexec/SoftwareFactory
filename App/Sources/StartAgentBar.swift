import SwiftUI
import SoftwareFactoryKit

/// Starting an agent, as the same control you talk to one with: a field, with what it may
/// do on the left and which CLI on the right, and a send button that starts it on those
/// words.
///
/// It was a card in a grid that opened a popover with a field in it, which is two steps in
/// front of one sentence. Starting an agent is saying the first thing to it, so it looks
/// like saying anything else to one: the field on a project's page and the field on an
/// agent's page are the same shape, in the same place, with the same two controls under
/// them. (T431, Alex, 15 Sep 2026.)
struct StartAgentBar: View {
    @Environment(AppModel.self) private var model
    var project: Project
    /// What the factory would say if you typed nothing.
    var words: String
    var launch: (AgentStart) -> Void

    @State private var typed = ""
    @State private var kind = LaunchAgent.remembered(nil)
    /// What to run this one on, seeded from the model Settings holds for the CLI picked
    /// above it and editable for this launch alone. Empty is that CLI's own default.
    @State private var runOn = ""
    /// The mode picked for this launch, in the agent's own words, or nil to follow the
    /// floor. Cleared when the CLI changes: the four do not share mode ids, and Claude
    /// Code's `bypassPermissions` means nothing to Cursor. (T466.)
    @State private var picked: ACP.Mode?

    private var isReady: Bool { project.path != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(prompt, text: $typed, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onSubmit(start)
                    .disabled(!isReady)
                DictateIntoField(words: $typed,
                                 about: "Software Factory listens on this Mac and turns what you say into the words the agent starts with. Nothing is recorded and nothing leaves the Mac.")
                    .disabled(!isReady)
                Button("Start", systemImage: "arrow.up.circle.fill", action: start)
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .disabled(!isReady)
                    .help(help)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Style.card))

            HStack(spacing: 8) {
                modeMenu
                Spacer(minLength: 8)
                modelField
                Menu {
                    ForEach(LaunchAgent.allCases) { one in
                        Button {
                            kind = one
                        } label: {
                            if one == kind { Label(one.title, systemImage: "checkmark") } else { Text(one.title) }
                        }
                    }
                } label: {
                    Text(kind.title).font(Style.Text.quiet)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Which CLI to start")
            }
            .padding(.horizontal, 6)
        }
        // Both controls are about the CLI above them, so both follow it: the model goes
        // back to whatever Settings holds for the one now picked, and the mode is dropped
        // rather than carried across, because a mode id belongs to the agent that named it.
        .onAppear { runOn = model.model(for: kind) }
        .onChange(of: kind) { _, now in
            runOn = model.model(for: now)
            picked = nil
        }
    }

    /// How much this one may do, chosen as it starts and in its own words. The list is
    /// what that CLI was measured offering (`LaunchAgent.modesOffered`), because nothing
    /// knows an agent's modes until it has handshaken and the choice is made before that.
    /// Follow Settings is the first row and names the floor's stance, so the ordinary case
    /// is one row rather than a decision. An agent with no modes of its own, which is Grok,
    /// gets the floor's own settings instead: that is all there is to say about it.
    /// (T466, Alex, 15 Sep 2026.)
    @ViewBuilder
    private var modeMenu: some View {
        let offered = kind.modesOffered
        Menu {
            if offered.isEmpty {
                ForEach(Throttle.Permissions.allCases) { stance in
                    Button {
                        model.setThrottle { $0.permissions = stance }
                    } label: {
                        if stance == model.throttle.permissions {
                            Label(stance.title, systemImage: "checkmark")
                        } else {
                            Text(stance.title)
                        }
                    }
                    .help(stance.detail)
                }
            } else {
                Button {
                    picked = nil
                } label: {
                    if picked == nil {
                        Label("Follow Settings: \(model.throttle.permissions.title)", systemImage: "checkmark")
                    } else {
                        Text("Follow Settings: \(model.throttle.permissions.title)")
                    }
                }
                Divider()
                ForEach(offered) { mode in
                    Button {
                        picked = mode
                    } label: {
                        if picked?.id == mode.id {
                            Label(mode.name, systemImage: "checkmark")
                        } else {
                            Text(mode.name)
                        }
                    }
                    .help(mode.detail ?? "")
                }
            }
        } label: {
            Text(picked?.name ?? model.throttle.permissions.title).font(Style.Text.quiet)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(offered.isEmpty
              ? "\(kind.title) has no modes of its own, so it follows how much agents may do"
              : "What \(kind.title) may do without asking, for this one agent")
    }

    /// What to run it on. A field rather than a menu: only Grok says what models it has,
    /// and then in a vendor extension, so there is no list to offer and a name typed is
    /// the honest control. Empty is the CLI's own default. (T462, T466.)
    private var modelField: some View {
        TextField("Default model", text: $runOn)
            .textFieldStyle(.plain)
            .font(Style.Text.quiet)
            .foregroundStyle(Color(.faint))
            .multilineTextAlignment(.trailing)
            .frame(width: 130)
            .disabled(!isReady)
            .help("Which model to start \(kind.title) on, for this one agent. Empty is its own default, and Settings holds the one every new \(kind.title) starts on.")
    }

    private var prompt: String {
        isReady ? "Start an agent on \(project.name)" : "Set the project's folder first"
    }

    private var help: String {
        if !isReady { return "Set the project folder before starting an agent" }
        if AgentLauncher.isSandboxed {
            return "This build is sandboxed, so an agent it started could not reach your own environment. The command goes on the clipboard instead."
        }
        return "Start \(kind.title) in the project's folder"
    }

    private func start() {
        guard isReady else { return }
        let said = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        typed = ""
        // Nothing typed is the ordinary case: the factory's own words are what an agent
        // working a backlog needs, and the field is there for when they are not.
        launch(AgentStart(style: model.launchStyle, kind: kind,
                          words: said.isEmpty ? words : said,
                          model: runOn.trimmingCharacters(in: .whitespacesAndNewlines),
                          mode: picked?.id ?? ""))
    }
}

/// What the person picked in the bar before pressing Start. It travels as one value
/// because it is one decision: this CLI, on this model, allowed this much, told this.
/// (T466.)
struct AgentStart {
    var style: AppModel.LaunchStyle
    var kind: LaunchAgent
    var words: String
    /// Empty is the CLI's own default.
    var model: String
    /// Empty is the floor's setting, the same as before there was a choice here.
    var mode: String
}
