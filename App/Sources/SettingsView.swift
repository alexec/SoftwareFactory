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
