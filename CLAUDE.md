# CLAUDE.md

Software Factory (code name Foreman) is a sandboxed macOS 26 SwiftUI app (Liquid Glass)
plus an MCP server. Agents register over MCP, work project backlogs, and raise questions;
the app shows the floor and records the person's decisions. `README.md` has the pitch and
the rules; `CONTRIBUTING.md` the promise; `BACKLOG.md` what is planned and refused;
`design/` the mockups.

## Build

`project.yml` is the source of truth; `Foreman.xcodeproj` is generated and git-ignored.
The Debug/Release settings are spelled out under `configs:` because this xcodegen has no
presets; `DEBUG` gates the Developer section of Settings.

```bash
xcodegen generate
xcodebuild -project Foreman.xcodeproj -scheme Foreman -configuration Debug \
  -destination "platform=macOS" -derivedDataPath build/DerivedData build
cd Packages/ForemanKit && swift test
cd Packages/ForemanKit && swift build -c release --product foreman   # the server, standalone
open build/DerivedData/Build/Products/Debug/Foreman.app
```

Check `bash ~/.claude/skills/task-board/assets/machine.sh --brief` immediately before
`xcodebuild`; if the Mac is claimed, do not build.

## Shape

- `Packages/ForemanKit` (Foundation only, `swift test`):
  - `Models`: `Project` (id is the folder path), `FactoryTask` (a task; named so because
    `Task` is Swift's; feature/bug/chore; backlog/inProgress/done; rank), `Agent` (name,
    project, task, lastSeen, deregistered; working within 2 min of a check-in),
    `Escalation` (options, one recommended; `decide(_:by:)` records a `Decision`).
  - `FileStore`: one JSON file per record under `projects/`, `tasks/`, `escalations/`,
    `agents/`; atomic writes; unreadable files skipped. `defaultRoot()` is the app group
    container or `$FOREMAN_STORE`.
  - `Backlog`: order, next rank, next task, move (onMove semantics), place above, state
    changes, current task.
  - `Dashboard.make(snapshot:now:)`: counts, one `ProjectStatus` per project, one
    `AgentStatus` per agent on the floor.
  - `MCPServer`: JSON-RPC 2.0 over stdio, `handle(_:)` is pure per request; `Tool.all`
    is the table; `call(_:_:)` does the work. `escalation_await` polls the store.
  - `SampleData`: records for a Debug build to look at.
  - `foreman` executable: `mcp` (the server), `status`, `tools`, `decide`.
- `App/Sources`:
  - `AppModel`: `@Observable @MainActor`; reloads the store every 2 s; every write goes
    through `persist`. `registerCommand` points at the server inside the bundle.
  - `RootView` (split view: Floor + projects), `FloorView` (stat tiles, Needs you as a
    horizontal strip, On the floor), `EscalationCard`, `ProjectView` (backlog with add,
    drag reorder, state menu), `IntroSheet`, `SettingsView` (How it works on top, the
    register command, the store, Developer in DEBUG).
- The `ForemanServer` tool target builds the same `foreman` sources with Xcode and is
  embedded at `Contents/MacOS/foreman-mcp`.

## Rules for changes

- A rule goes in the package with a test before it goes in a view.
- Never change a record's JSON shape without a reader for the old shape.
- A new tool: add it to `Tool.all` and `call`, and a test in `MCPServerTests`.
- Every string a person reads follows `alex-writing-voice`; no em dashes.
- First-run: the sheet shows once (`hasSeenIntro`) and again from Settings. Reset with the
  Developer row or `defaults delete com.alexecollins.foreman hasSeenIntro`.
- Try the floor with data: Settings ▸ Developer ▸ Add sample data, or drive the server by
  hand: `printf '...json-rpc...\n' | foreman mcp`.
