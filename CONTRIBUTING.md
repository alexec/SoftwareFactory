# Contributing

## The promise comes first

1. **It reads what is there.** Foreman never asks an agent to do anything special to be
   seen. Claude Code's own files are the source of truth for sessions; the store is the
   source of truth for work. If a session is running, it is on the dashboard.
2. **The store is shared, and the file format is the API.** Anything that can write a
   JSON file can file a task or raise a question: the app, the command line, an MCP
   server, an iPhone. Never make the app the only writer, and never change a record's
   shape without a version bump and a reader that copes with the old one.
3. **Nothing leaves the Mac.** No accounts, no telemetry, no network. When the iPhone app
   arrives, sync goes through the person's own iCloud and nothing else.
4. **Agents ask; the person decides.** An escalation always carries options and a
   recommendation, so answering is one click. The app never makes the choice itself and
   never nags: an open question sits at the top until it is answered.
5. **Thin, then thinner.** Each feature arrives on its own. Resource locks, MCP, the
   iPhone, Apple Intelligence and transcription are all planned and none is started early.
6. **Private and free forever.** No purchases of any kind.

## Where things go

- **Rules in the package.** `Packages/ForemanKit` is Foundation only and holds every rule:
  the records, the store, the Claude Code scanner, the backlog order, the dashboard
  derivation. It is tested with `swift test`. If a view is deciding something, move the
  decision into the package and write the test.
- **Plumbing in the app.** `App/Sources` is a thin SwiftUI shell: the model that refreshes,
  the bookmark to the Claude folder, the views.
- **The command line** in `Packages/ForemanKit/Sources/foreman` is the agents' way in
  until the MCP server exists, and the MCP server will call the same package.

## Style

Swift 6, strict concurrency, macOS 26 with Liquid Glass. Records are `Codable`, `Sendable`
and `Equatable`. Copy inside the app is Alex's prose: no template phrases, no em dashes,
say why. The first-run sheet is the only place that explains; the screens explain
themselves.

The working screen on open is **ready on open**: the dashboard, with empty states that
show the shape of what will fill them.
