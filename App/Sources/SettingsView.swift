import AppKit
import SwiftUI
import SoftwareFactoryKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(TerminalSessions.self) private var terminals
    @Environment(Floor.self) private var floor
    @Environment(\.openWindow) private var openWindow
    @State private var showingIntro = false
    @State private var copiedInstall = false
    @State private var installError: String?

    var body: some View {
        Form {
            Section {
                Button("How it works") { showingIntro = true }
                Button(AgentSetupHelp.title) { openWindow(id: AgentSetupHelp.windowID) }
            }

            Section("Notifications") {
                switch model.notifier.standing {
                case .unknown:
                    Text("Checking.").foregroundStyle(Color(.quiet))
                case .notAsked:
                    Text("Not asked yet. The dashboard asks the first time.")
                        .foregroundStyle(Color(.quiet))
                case .allowed:
                    Text("A banner for each new question, with the options as its actions.")
                        .foregroundStyle(Color(.quiet))
                case .denied:
                    Text("Banners are off. They can be turned on for Taktu: Software Factory in System Settings, Notifications.")
                        .foregroundStyle(Color(.quiet))
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                LabeledContent("You", value: model.isAtTheMac ? "At the Mac" : "Away")
                Text("At the Mac means the screen is unlocked and something was typed or clicked in the last two minutes.")
                    .foregroundStyle(Color(.quiet))
            }

            Section("iCloud") {
                LabeledContent("Sync", value: model.cloud.summary)
                Text("Questions and decisions go through your own iCloud so the phone works away from this network.")
                    .foregroundStyle(Color(.quiet))
            }

            Section("Agent") {
                Picker("Runs", selection: launchStyleBinding) {
                    ForEach(AppModel.LaunchStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .disabled(AgentLauncher.isSandboxed)
                Text(model.launchStyle.detail)
                    .foregroundStyle(Color(.quiet))
                if AgentLauncher.isSandboxed {
                    Text("This build is sandboxed, so it copies the command for you to paste instead of starting anything itself.")
                        .foregroundStyle(Color(.quiet))
                }
            }

            // How much an agent may do without stopping to ask. Before ACP every agent was
            // launched with its own auto-approve flag, because there was nobody on the
            // other end to ask. The flags are gone and this replaced them, so the default
            // is the behaviour that was already there. (T373.)
            Section("Asking") {
                Picker("Agents", selection: Binding(
                    get: { model.throttle.permissions },
                    set: { picked in model.setThrottle { $0.permissions = picked } })) {
                    ForEach(Throttle.Permissions.allCases) { stance in
                        Text(stance.title).tag(stance)
                    }
                }
                Text(model.throttle.permissions.detail)
                    .foregroundStyle(Color(.quiet))
                    .fixedSize(horizontal: false, vertical: true)
                if model.throttle.permissions == .agentDecides {
                    Text("Where an agent has no mode of its own for this, the factory says yes on its behalf, which is the nearest thing it has.")
                        .font(.callout)
                        .foregroundStyle(Color(.quiet))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("This is the floor's setting. An agent's own page can put that one somewhere else, and it stays where you put it.")
                    .font(.callout)
                    .foregroundStyle(Color(.quiet))
                    .fixedSize(horizontal: false, vertical: true)
                if model.throttle.permissions != .allowEverything && model.throttle.permissions != .agentDecides {
                    Text("A question stops the agent until it is answered, so one raised while you are away is an agent doing nothing. The factory takes the recommendation after ten minutes and says so.")
                        .font(.callout)
                        .foregroundStyle(Color(.quiet))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // The daemon that holds the ACP agents. It is the reason an agent survives a
            // rebuild, so what it is holding is worth being able to see. (T373.)
            Section("Agents that speak ACP") {
                LabeledContent("Daemon", value: floor.isUp
                               ? "Running, pid \(floor.daemonPID.map(String.init) ?? "?")"
                               : "Not running")
                if floor.isUp {
                    LabeledContent("Holding", value: floor.held.isEmpty
                                   ? "Nothing"
                                   : floor.held.values.map { one in
                                       (model.snapshot.agents.first { $0.id == one.agent }?.label
                                        ?? String(one.agent.uuidString.prefix(8)))
                                       + " (\(one.state.rawValue))"
                                   }.sorted().joined(separator: ", "))
                }
                Text(floor.isUp
                     ? "Claude Code and GitHub Copilot run as ACP agents, held by a daemon of their own so they keep working when this app is rebuilt. Their pages show what they are doing rather than a terminal."
                     : "It starts itself the first time you launch an agent that speaks ACP. Grok, Cursor and a plain Terminal do not, and keep their terminals.")
                    .foregroundStyle(Color(.quiet))
                    .fixedSize(horizontal: false, vertical: true)
                if let trouble = floor.trouble {
                    Text(trouble).foregroundStyle(.red)
                }
                if Floor.binary == nil {
                    Text("software-factory is not on this Mac, so nothing can hold an ACP agent. Build it with: swift build --package-path Packages/SoftwareFactoryKit")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Sessions that outlive the app, when tmux is here to hold them.
            Section("Sessions for agents in a terminal") {
                if Tmux.isInstalled {
                    Toggle("Keep sessions after quitting", isOn: Binding(
                        get: { model.usesTmux }, set: { model.usesTmux = $0 }))
                    Text(model.usesTmux
                         ? "An agent you launch runs in a tmux session of its own, so it keeps working when this app quits, and its page picks it back up. You never see tmux: no status bar, no prefix key, its own server, its own settings."
                         : "An agent you launch is this app's own child and ends when you quit.")
                        .foregroundStyle(Color(.quiet))
                        .fixedSize(horizontal: false, vertical: true)
                    // What is held comes from TerminalSessions rather than from tmux
                    // itself: asking tmux here would run it while the window is drawing.
                    // (Alex, 13 Sep 2026.)
                    if model.usesTmux, !terminals.held.isEmpty {
                        LabeledContent("Held now", value: terminals.held.sorted().joined(separator: ", "))
                    }
                } else {
                    LabeledContent("tmux", value: "Not installed")
                    Text("An agent launched in the app is this app's own child and ends when you quit. tmux can hold the session instead, so agents keep working between runs. You would never see it.")
                        .foregroundStyle(Color(.quiet))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Install tmux") {
                            do { try Tmux.install() } catch { installError = error.localizedDescription }
                        }
                        Button(copiedInstall ? "Copied" : "Copy the command") {
                            AgentLauncher.copyCommand("brew install tmux")
                            copiedInstall = true
                        }
                    }
                    if let installError {
                        Text(installError).foregroundStyle(.red)
                    }
                }
            }

            Section("Store") {
                if let store = model.store {
                    LabeledContent("Folder", value: Projects.shortPath(store.root.path))
                    Text("Every project, task, agent and question is one JSON file.")
                        .foregroundStyle(Color(.quiet))
                }
                if let error = model.storeError {
                    Text(error).foregroundStyle(.red)
                }
            }

            #if DEBUG
            Section("Developer") {
                LabeledContent("Last banner", value: model.notifier.lastPost)
                LabeledContent("Delivered now", value: model.notifier.delivered.formatted())
                Button("Show the first-run sheet again") { model.hasSeenIntro = false }
                Button("Add sample data") { model.addSampleData() }
                if let store = model.store {
                    Button("Reveal the store in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.root])
                    }
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(.paper))
        .tint(Color(.mark))
        .frame(width: 720, height: 640)
        .task { await terminals.lookForHeldSessions() }
        .task { await floor.look() }
        .sheet(isPresented: $showingIntro) { IntroSheet() }
    }

    private var launchStyleBinding: Binding<AppModel.LaunchStyle> {
        Binding(get: { model.launchStyle }, set: { model.launchStyle = $0 })
    }

}
