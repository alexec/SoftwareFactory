import AppKit
import SwiftUI
import ForemanKit

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
                Text("Agents reach the factory through its MCP server, which ships inside this app. Register it with Claude Code once:")
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
                    Text("The server writes here too. Every project, task, agent and question is one JSON file.")
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
