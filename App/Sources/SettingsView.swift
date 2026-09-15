import AppKit
import SwiftUI
import SoftwareFactoryKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(TerminalSessions.self) private var terminals
    @State private var showingIntro = false
    @State private var copiedInstall = false
    @State private var installError: String?

    var body: some View {
        Form {
            Section {
                Button("How it works") { showingIntro = true }
            }

            Section("Notifications") {
                switch model.notifier.standing {
                case .unknown:
                    Text("Checking.").foregroundStyle(.secondary)
                case .notAsked:
                    Text("Not asked yet. The dashboard asks the first time.")
                        .foregroundStyle(.secondary)
                case .allowed:
                    Text("A banner for each new question, with the options as its actions.")
                        .foregroundStyle(.secondary)
                case .denied:
                    Text("Banners are off. They can be turned on for Taktu: Software Factory in System Settings, Notifications.")
                        .foregroundStyle(.secondary)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                LabeledContent("You", value: model.isAtTheMac ? "At the Mac" : "Away")
                Text("At the Mac means the screen is unlocked and something was typed or clicked in the last two minutes.")
                    .foregroundStyle(.secondary)
            }

            Section("iCloud") {
                LabeledContent("Sync", value: model.cloud.summary)
                Text("Questions and decisions go through your own iCloud so the phone works away from this network.")
                    .foregroundStyle(.secondary)
            }

            Section("Agent") {
                Picker("Runs", selection: launchStyleBinding) {
                    ForEach(AppModel.LaunchStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .disabled(AgentLauncher.isSandboxed)
                Text(model.launchStyle.detail)
                    .foregroundStyle(.secondary)
                if AgentLauncher.isSandboxed {
                    Text("This build is sandboxed, so it copies the command for you to paste instead of starting anything itself.")
                        .foregroundStyle(.secondary)
                }
            }

            // Sessions that outlive the app, when tmux is here to hold them.
            Section("Sessions") {
                if Tmux.isInstalled {
                    Toggle("Keep sessions after quitting", isOn: Binding(
                        get: { model.usesTmux }, set: { model.usesTmux = $0 }))
                    Text(model.usesTmux
                         ? "An agent you launch runs in a tmux session of its own, so it keeps working when this app quits, and its page picks it back up. You never see tmux: no status bar, no prefix key, its own server, its own settings."
                         : "An agent you launch is this app's own child and ends when you quit.")
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
        .frame(width: 720, height: 640)
        .task { await terminals.lookForHeldSessions() }
        .sheet(isPresented: $showingIntro) { IntroSheet() }
    }

    private var launchStyleBinding: Binding<AppModel.LaunchStyle> {
        Binding(get: { model.launchStyle }, set: { model.launchStyle = $0 })
    }

}
