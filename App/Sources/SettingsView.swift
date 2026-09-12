import AppKit
import SwiftUI
import ForemanKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingIntro = false

    var body: some View {
        Form {
            Section {
                Button("How it works") { showingIntro = true }
            }

            Section("Claude Code") {
                if let url = model.claudeFolder.url {
                    LabeledContent("Folder", value: url.path)
                    Button("Choose a different folder") { model.claudeFolder.choose() }
                } else {
                    Text("Foreman reads Claude Code's session files to see what each agent is doing. Nothing leaves this Mac.")
                        .foregroundStyle(.secondary)
                    Button("Choose the Claude folder") { model.claudeFolder.choose() }
                }
            }

            Section("Store") {
                if let store = model.store {
                    LabeledContent("Folder", value: store.root.path)
                    Text("Agents write here too. Every project, task and escalation is one JSON file.")
                        .foregroundStyle(.secondary)
                } else if let error = model.storeError {
                    Text(error).foregroundStyle(.red)
                }
            }

            #if DEBUG
            Section("Developer") {
                Button("Show the first-run sheet again") { model.hasSeenIntro = false }
                Button("Add sample data") { model.addSampleData() }
                Button("Forget the Claude folder") { model.claudeFolder.forget() }
                if let store = model.store {
                    Button("Reveal the store in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.root])
                    }
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .sheet(isPresented: $showingIntro) { IntroSheet() }
    }
}
