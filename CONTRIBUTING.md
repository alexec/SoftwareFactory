# Contributing

## The promise comes first

1. **The factory is ignorant of what an agent runs on.** An agent is anything that speaks
   MCP. It says who it is, what it is on, and what it needs; the app never reads another
   tool's files to guess.
2. **The store is shared, and the file format is the API.** The MCP server and the app
   both write it; the iPhone will read it through iCloud. Never make the app the only
   writer, and never change a record's shape without a reader that copes with the old one.
3. **Nothing leaves the Mac.** No accounts, no telemetry, no network. When the iPhone app
   arrives, sync goes through the person's own iCloud and nothing else.
4. **Agents ask; the person decides.** An escalation always carries options and a
   recommendation, so answering is one click. The app never makes the choice itself and
   never nags: an open question sits at the top until it is answered.
5. **Thin, then thinner.** Each feature arrives on its own. Resources, capacity, notifications, the
   iPhone and dictation are all planned and none is started early.
6. **Private and free forever.** No purchases of any kind.

## Where things go

- **Rules in the package.** `Packages/ForemanKit` is Foundation only and holds every rule:
  the records, the store, the backlog order, the floor derivation, and the MCP server's
  tools. It is tested with `swift test`. If a view is deciding something, move the
  decision into the package and write the test.
- **Plumbing in the app.** `App/Sources` is a thin SwiftUI shell: the model that refreshes,
  the views, the command that registers the server.
- **The server** in `Packages/ForemanKit/Sources/foreman` is `foreman mcp`, built twice:
  by SwiftPM for `swift test` and the shell, and by Xcode into the app bundle.

## Style

Swift 6, strict concurrency, macOS 26 with Liquid Glass. Records are `Codable`, `Sendable`
and `Equatable`. Copy inside the app is Alex's prose: no template phrases, no em dashes,
say why. The first-run sheet is the only place that explains; the screens explain
themselves.

The working screen on open is **ready on open**: the dashboard, with empty states that
show the shape of what will fill them.
