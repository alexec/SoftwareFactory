// foreman: the command line into the shared store, for agents and for scripts.
// The MCP server will sit on the same calls; until then a shell command is enough.
//
//   foreman status
//   foreman projects
//   foreman project add <path>
//   foreman task list [<project>]
//   foreman task add <project> "<title>" [--kind feature|bug|chore] [--note "..."]
//   foreman task start <id-prefix> [--agent <name>]
//   foreman task done <id-prefix>
//   foreman escalate <project> "<question>" --option "Title|detail" [--option ...]
//                    [--recommend N] [--context "..."] [--by <agent>]
//   foreman decide <escalation-id-prefix> <option-number>
//
// <project> is a folder path or a project name already in the store. The store is
// $FOREMAN_STORE or the app group container; `foreman status` prints where.

import Foundation
import ForemanKit

struct Usage: Error, CustomStringConvertible {
    var description: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

struct Args {
    var positional: [String] = []
    var flags: [String: [String]] = [:]

    init(_ argv: ArraySlice<String>) {
        var it = argv.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                let value = it.next() ?? ""
                flags[key, default: []].append(value)
            } else {
                positional.append(a)
            }
        }
    }

    func flag(_ key: String) -> String? { flags[key]?.last }
    func all(_ key: String) -> [String] { flags[key] ?? [] }
}

let store: FileStore
do {
    store = try FileStore(root: FileStore.defaultRoot())
} catch {
    fail("Could not open the store: \(error)")
}

func snapshot() -> Snapshot {
    do { return try store.load() } catch { fail("Could not read the store: \(error)") }
}

/// A path or a name. A path that is not yet a project becomes one, so an agent can file
/// against its own folder without a step first.
func resolveProject(_ ref: String, in snap: Snapshot, create: Bool) -> Project {
    if let p = snap.projects.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) { return p }
    let path = Project.canonical(ref.hasPrefix("/") ? ref : FileManager.default.currentDirectoryPath + "/" + ref)
    if let p = snap.projects.first(where: { $0.id == path }) { return p }
    guard create, FileManager.default.fileExists(atPath: path) else {
        fail("No project called \(ref). Give a folder path, or one of: \(snap.projects.map(\.name).joined(separator: ", "))")
    }
    let p = Project(path: path)
    do { try store.save(p) } catch { fail("Could not save the project: \(error)") }
    return p
}

func find<T: Identifiable>(_ prefix: String, in records: [T]) -> T where T.ID == UUID {
    let matches = records.filter { $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) }
    guard matches.count == 1 else {
        fail(matches.isEmpty ? "Nothing matches \(prefix)." : "\(matches.count) records match \(prefix); give more of the id.")
    }
    return matches[0]
}

func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

let args = Args(CommandLine.arguments.dropFirst())
let command = args.positional.first ?? "status"
let rest = Array(args.positional.dropFirst())

switch command {
case "status":
    let snap = snapshot()
    let scanner = ClaudeCodeScanner(root: ClaudeCodeScanner.defaultRoot())
    let sessions = (try? scanner.scan()) ?? []
    let dash = Dashboard.make(snapshot: snap, sessions: sessions)
    print("Store: \(store.root.path)")
    print("In progress: \(dash.inProgress)   Needs you: \(dash.openEscalations.count)   Working: \(dash.workingCount) of \(dash.projects.count)")
    for p in dash.projects {
        let doing = p.doing.map { " · \($0)" } ?? ""
        print("  \(p.activity.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(p.project.name)\(doing)")
    }
    for e in dash.openEscalations {
        let project = snap.projects.first { $0.id == e.projectID }?.name ?? e.projectID
        print("  ? \(short(e.id)) [\(project)] \(e.question)")
        for (n, o) in e.options.enumerated() {
            print("      \(n + 1). \(o.title)\(o.recommended ? "  (recommended)" : "")")
        }
    }

case "projects":
    for p in snapshot().projects.sorted(by: { $0.name < $1.name }) { print("\(p.name)\t\(p.path)") }

case "project":
    guard rest.first == "add", let path = rest.dropFirst().first else { fail("foreman project add <path>") }
    let p = resolveProject(path, in: snapshot(), create: true)
    print("\(p.name)\t\(p.path)")

case "task":
    let snap = snapshot()
    switch rest.first {
    case "list":
        let items = rest.dropFirst().first.map { ref in
            Backlog.items(for: resolveProject(ref, in: snap, create: false).id, in: snap.items)
        } ?? snap.items.sorted(by: Backlog.order)
        for i in items {
            let project = snap.projects.first { $0.id == i.projectID }?.name ?? i.projectID
            print("\(short(i.id))\t\(i.state.rawValue)\t\(i.kind.rawValue)\t[\(project)] \(i.title)")
        }
    case "add":
        guard rest.count >= 3 else { fail("foreman task add <project> \"<title>\" [--kind bug] [--note ...]") }
        let project = resolveProject(rest[1], in: snap, create: true)
        let kind = args.flag("kind").flatMap(WorkItem.Kind.init(rawValue:)) ?? .feature
        let item = WorkItem(projectID: project.id, title: rest[2], kind: kind,
                            rank: Backlog.nextRank(for: project.id, in: snap.items), note: args.flag("note") ?? "")
        do { try store.save(item) } catch { fail("Could not save: \(error)") }
        print(short(item.id))
    case "start", "done", "backlog":
        guard rest.count >= 2 else { fail("foreman task \(rest[0]) <id-prefix>") }
        let item = find(rest[1], in: snap.items)
        let state: WorkItem.State = rest[0] == "start" ? .inProgress : rest[0] == "done" ? .done : .backlog
        do { try store.save(Backlog.set(item, to: state, agent: args.flag("agent"))) } catch { fail("Could not save: \(error)") }
        print("\(short(item.id)) \(state.rawValue)")
    default:
        fail("foreman task list|add|start|done|backlog")
    }

case "escalate":
    guard rest.count >= 2 else {
        fail("foreman escalate <project> \"<question>\" --option \"Title|detail\" [--option ...] [--recommend N] [--context ...] [--by <agent>]")
    }
    let snap = snapshot()
    let project = resolveProject(rest[0], in: snap, create: true)
    let recommend = args.flag("recommend").flatMap(Int.init) ?? 1
    let options = args.all("option").enumerated().map { n, raw -> Escalation.Option in
        let parts = raw.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return .init(title: parts.first ?? raw, detail: parts.count > 1 ? parts[1] : "", recommended: n + 1 == recommend)
    }
    guard options.count >= 2 else { fail("An escalation needs at least two --option values.") }
    let e = Escalation(projectID: project.id, question: rest[1], context: args.flag("context") ?? "",
                       options: options, raisedBy: args.flag("by") ?? "agent")
    do { try store.save(e) } catch { fail("Could not save: \(error)") }
    print(short(e.id))

case "decide":
    guard rest.count >= 2, let n = Int(rest[1]) else { fail("foreman decide <escalation-id-prefix> <option-number>") }
    let snap = snapshot()
    var e = find(rest[0], in: snap.escalations)
    guard n >= 1, n <= e.options.count else { fail("Options run 1 to \(e.options.count).") }
    do {
        try e.decide(e.options[n - 1])
        try store.save(e)
    } catch { fail("Could not record the decision: \(error)") }
    print("\(short(e.id)) → \(e.options[n - 1].title)")

case "escalations":
    let snap = snapshot()
    for e in snap.escalations.sorted(by: { $0.raised < $1.raised }) {
        let project = snap.projects.first { $0.id == e.projectID }?.name ?? e.projectID
        let state = e.chosen.map { "→ \($0.title)" } ?? "open"
        print("\(short(e.id))\t[\(project)] \(e.question)\t\(state)")
    }

default:
    fail("foreman status|projects|project|task|escalate|escalations|decide")
}
