import AppKit
import SwiftUI
import SoftwareFactoryKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingIntro = false
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Button("How it works") { showingIntro = true }
            }

            Section("Agents") {
                LabeledContent("Factory", value: model.serverState)
                Text("Agents reach the factory over MCP on this port while the app is running. Register it with Claude Code once:")
                    .foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text(AppModel.registerCommand)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AppModel.registerCommand, forType: .string)
                        copied = true
                    }
                }
            }

            Section("Notifications") {
                switch model.notifier.standing {
                case .notAsked:
                    Text("Not asked yet. The floor asks the first time.")
                        .foregroundStyle(.secondary)
                case .allowed:
                    Text("A banner for each new question, with the options as its actions.")
                        .foregroundStyle(.secondary)
                case .denied:
                    Text("Banners are off. They can be turned on for Software Factory in System Settings, Notifications.")
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

            Section("Apple Intelligence") {
                Text(TaskTitler.isAvailable
                     ? "A long sentence typed or dictated as a task becomes a short title, with the rest kept as the note. On this Mac; nothing leaves it."
                     : "Not available on this Mac, so what you type or say is the title as it is.")
                    .foregroundStyle(.secondary)
            }

            Section("iCloud") {
                LabeledContent("Sync", value: model.cloud.summary)
                Text("Questions and decisions go through your own iCloud so the phone works away from this network.")
                    .foregroundStyle(.secondary)
            }

            Section("Store") {
                if let store = model.store {
                    LabeledContent("Folder", value: store.root.path)
                    Text("Every project, task, agent and question is one JSON file.")
                        .foregroundStyle(.secondary)
                } else if let error = model.storeError {
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
        .frame(width: 560)
        .sheet(isPresented: $showingIntro) { IntroSheet() }
    }
}
