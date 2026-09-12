# CLAUDE.md

Software Factory is a sandboxed macOS 26 SwiftUI app (Liquid Glass) that hosts an MCP
server on port 4747, and an iPhone app that is its remote over the local network. Agents register over MCP, work project backlogs, and raise questions;
the app shows the floor and records the person's decisions. `README.md` has the pitch and
the rules; `CONTRIBUTING.md` the promise; `BACKLOG.md` what is planned and refused;
`design/` the mockups.

## Build

`project.yml` is the source of truth; `SoftwareFactory.xcodeproj` is generated and git-ignored.
The Debug/Release settings are spelled out under `configs:` because this xcodegen has no
presets; `DEBUG` gates the Developer section of Settings.

```bash
xcodegen generate
xcodebuild -project SoftwareFactory.xcodeproj -scheme SoftwareFactory -configuration Debug \
  -destination "platform=macOS" -derivedDataPath build/DerivedData build
xcodebuild -project SoftwareFactory.xcodeproj -scheme SoftwareFactoryPhone -configuration Debug \
  -destination "generic/platform=iOS Simulator" -derivedDataPath build/DerivedData build
cd Packages/SoftwareFactoryKit && swift test
open "build/DerivedData/Build/Products/Debug/Software Factory.app"
```

Check `bash ~/.claude/skills/task-board/assets/machine.sh --brief` immediately before
`xcodebuild`; if the Mac is claimed, do not build.

## Shape

- `Packages/SoftwareFactoryKit` (Foundation only, `swift test`):
  - `Models`: `Project` (id is the folder path), `FactoryTask` (a task; named so because
    `Task` is Swift's; feature/bug/chore; backlog/inProgress/done; rank), `Agent` (name,
    project, task, lastSeen, deregistered; working within 2 min of a check-in),
    `Escalation` (options, one recommended; `decide(_:by:)` records a `Decision`).
  - `FileStore`: one JSON file per record under `projects/`, `tasks/`, `escalations/`,
    `agents/`; atomic writes; unreadable files skipped. `defaultRoot()` is the app group
    container or `$SOFTWARE_FACTORY_STORE`.
  - `Backlog`: order, next rank, next task, move (onMove semantics), place above, state
    changes, current task.
  - `Dashboard.make(snapshot:now:)`: counts, one `ProjectStatus` per project, one
    `AgentStatus` per agent on the floor.
  - `MCPServer`: JSON-RPC 2.0, `handle(_:)` is pure per request; `Tool.all` is the
    table; `call(_:_:)` does the work. `escalation_await` polls the store.
  - `HTTP`: `HTTPRequest.parse`, `HTTPResponse.serialized`, and `HTTPRouter` (`POST /mcp`,
    `GET /api/snapshot`, `POST /api/decide`, `POST /api/task`; browser origins refused).
  - `SampleData`: records for a Debug build to look at.
  - `software-factory` executable: `mcp` (the server over stdio), `status`, `tools`, `decide`.
- `App/Sources`:
  - `AppModel`: `@Observable @MainActor`; reloads the store every 2 s; every write goes
    through `persist`; starts `FactoryServer` on port 4747.
  - `FactoryServer`: `NWListener` on the port, one queue per connection (a request can
    block for minutes), Bonjour `_softwarefactory._tcp`.
  - `RootView` (split view: Floor + projects), `FloorView` (stat tiles, Needs you as a
    horizontal strip, On the floor), `EscalationCard`, `ProjectView` (backlog with add,
    drag reorder, state menu), `IntroSheet`, `SettingsView` (How it works on top, the
    register command, the store, Developer in DEBUG).
- `Phone/Sources`: `PhoneModel` (NWBrowser finds the factory, resolves host and port with
  one probe connection, polls `/api/snapshot` every 3 s, posts `/api/decide`),
  `PhoneRootView` (network primer in place, Needs you, On the floor), `PhoneIntroSheet`,
  `PhoneSettingsView`. Same bundle id as the Mac app.

## Rules for changes

- A rule goes in the package with a test before it goes in a view.
- Never change a record's JSON shape without a reader for the old shape.
- A new tool: add it to `Tool.all` and `call`, and a test in `MCPServerTests`.
- Every string a person reads follows `alex-writing-voice`; no em dashes.
- First-run: the sheet shows once (`hasSeenIntro`) and again from Settings. Reset with the
  Developer row or `defaults delete com.alexecollins.softwarefactory hasSeenIntro`.
- Try the floor with data: Settings ▸ Developer ▸ Add sample data, or drive the server by
  hand: `printf '...json-rpc...\n' | software-factory mcp`.
