// software-factory: the factory's MCP server, plus a few commands for a person at a shell.
//
//   software-factory mcp                       run the MCP server on stdio (what Claude Code launches)
//   software-factory status                    the dashboard, as text
//   software-factory tools                     the tool names and what they do
//   software-factory decide <escalation-id-prefix> <option-number>
//   software-factory quit                      quit the running Mac app, properly (T271)
//
// The store is $SOFTWARE_FACTORY_STORE or the app group container; `software-factory status` prints where.

import Foundation
import SoftwareFactoryKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let store: FileStore
do {
    store = try FileStore(root: FileStore.defaultRoot())
} catch {
    fail("Could not open the store: \(error)")
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "status"

switch command {
case "mcp":
    MCPServer(store: store).serve()

case "status":
    let snap = (try? store.load()) ?? Snapshot()
    let dash = Dashboard.make(snapshot: snap)
    print("Store: \(store.root.path)")
    print("In progress: \(dash.inProgress)   Need you: \(dash.openEscalations.count)   Agents: \(dash.agents.count)")
    for a in dash.agents {
        let on = a.task.map { " · \($0.title)" } ?? (a.agent.note.isEmpty ? "" : " · \(a.agent.note)")
        let word = a.activity.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
        print("  \(word) \(a.agent.label) [\(a.project?.name ?? "-")]\(on)\(a.waitingOnYou ? " · waiting on you" : "")")
    }
    for p in dash.projects {
        let doing = p.doing.map { " · \($0)" } ?? ""
        print("  \(p.activity.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(p.project.name)\(doing)")
    }
    for e in dash.openEscalations {
        let project = snap.projects.first { $0.id == e.projectID }?.name ?? e.projectID
        print("  ? \(e.id.uuidString.prefix(8).lowercased()) [\(project)] \(e.question)")
        for (n, o) in e.options.enumerated() {
            print("      \(n + 1). \(o.title)\(o.recommended ? "  (recommended)" : "")")
        }
    }

// Stopping the app the way its own Quit menu item does, from a terminal where
// `osascript ... to quit` silently does nothing. (T271.)
case "quit":
    guard let app = store.factoryProcess() else {
        fail("The store has no record of a running app. Start Software Factory, or stop it with: pkill -f 'Software Factory.app/Contents/MacOS'")
    }
    guard app.isRunning else {
        print("Nothing to quit: the app that wrote \(store.root.path)/app.json has already gone.")
        exit(0)
    }
    guard ProcessCheck.quit(pid: app.pid, startedAt: app.startedAt) else {
        fail("The quit event did not go out to \(app.pid).")
    }
    // It has gone when the kernel says so, not when the event was sent.
    var waited = 0.0
    while waited < 10, ProcessCheck.isRunning(pid: app.pid, startedAt: app.startedAt) {
        Thread.sleep(forTimeInterval: 0.2)
        waited += 0.2
    }
    if ProcessCheck.isRunning(pid: app.pid, startedAt: app.startedAt) {
        fail("Asked \(app.pid) to quit and it is still there after 10 seconds.")
    }
    print("Quit. \(app.pid) has gone.")

case "tools":
    for t in MCPServer.Tool.all { print("\(t.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(t.description)") }

case "decide":
    guard args.count >= 3, let n = Int(args[2]) else { fail("software-factory decide <escalation-id-prefix> <option-number>") }
    let snap = (try? store.load()) ?? Snapshot()
    let matches = snap.escalations.filter { $0.id.uuidString.lowercased().hasPrefix(args[1].lowercased()) }
    guard matches.count == 1, var e = matches.first else { fail("\(matches.count) escalations match \(args[1])") }
    guard n >= 1, n <= e.options.count else { fail("Options run 1 to \(e.options.count).") }
    do {
        try e.decide(e.options[n - 1], by: "shell")
        try store.save(e)
    } catch { fail("Could not record the decision: \(error)") }
    print("\(e.question) → \(e.options[n - 1].title)")

default:
    fail("software-factory mcp|status|tools|decide")
}
