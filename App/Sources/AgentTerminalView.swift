import AppKit
import SoftwareFactoryKit
import SwiftTerm
import SwiftUI

struct AgentTerminalSheet: View {
    let project: Project
    let command: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.headline)
                    Text(project.path ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()

            if let path = project.path, !path.isEmpty {
                LocalAgentTerminalView(command: command, workingDirectory: path)
                    .background(.black)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

struct LocalAgentTerminalView: NSViewRepresentable {
    let command: String
    let workingDirectory: String

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["-lc", command],
            currentDirectory: workingDirectory
        )
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: ()) {
        nsView.terminate()
    }
}
