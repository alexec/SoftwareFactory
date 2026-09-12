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
    `Task` is Swift's; feature/bug/chore; backlog/inProgress/done/parked/blocked with a
    `Blocker` saying what on; rank), `Agent` (name,
    project, task, lastSeen, deregistered; working within 2 min of a check-in),
    `Escalation` (options, one recommended; `decide(_:by:)` records a `Decision`),
    `Resource` (slots, maxLease), `Lease` (one slot, one agent, until; `isActive(now:)`).
  - `FileStore`: one JSON file per record under `projects/`, `tasks/`, `escalations/`,
    `agents/`, `resources/`, `leases/`; atomic writes; unreadable files skipped.
    `Snapshot` decodes with missing collections as empty, for older clients. `defaultRoot()` is the app group
    container or `$SOFTWARE_FACTORY_STORE`.
  - `Backlog`: order (in progress, backlog, parked, done), next rank, top rank, next
    task, move (onMove semantics; parked sits out), place above, state changes,
    `personMaySet` (backlog and parked only), current task, `visible`.
  - `Leases`: active leases, free slots, lease (renews if already held; full says when a
    slot frees), renew, release, heldBy, stale.
  - `CloudRecords`: each record as one CloudKit record (`json`, `updated`); diff for
    pushes; `decisionsToAdopt` for decisions made on another device.
  - `Escalations.visible`: open questions in full, the newest three answered ones.
  - `Sweep.goneAgents`: fifteen silent minutes and an agent is marked gone, leases released.
  - `Sweep.unblocked`: a task blocked on a decision now made, or a task now done, goes
    back to the backlog with a line saying so. A block on a person clears by hand.
  - `Records.version` on every record; a decoder reads an older shape without it.
  - `Capacity`: `MachineReading` (`sample()` on macOS reads memory, swap, load, compiles,
    simulators through sysctl and Mach), `Throttle` (one file, `throttle.json`), the
    verdict, the reason, and `ask(work:)` for compile, simulator, model.
  - `Dashboard.make(snapshot:now:)`: counts, one `ProjectStatus` per project, one
    `AgentStatus` per agent on the floor.
  - `MCPServer`: JSON-RPC 2.0, `handle(_:)` is pure per request; `Tool.all` is the
    table; `call(_:_:)` does the work. `escalation_await` polls the store.
  - `HTTP`: `HTTPRequest.parse`, `HTTPResponse.serialized`, and `HTTPRouter` (`POST /mcp`,
    `GET /api/snapshot`, `POST /api/decide`, `POST /api/task`; browser origins refused).
  - `SampleData`: records for a Debug build to look at.
  - `Shared/CloudSync.swift` (both apps, not the package): the CloudKit calls. Container
    `iCloud.com.alexecollins.softwarefactory`, private database, query on `updated`.
  - `Shared/Dictation.swift`: `SpeechAnalyzer` on device; `volatile` and `settled` text.
  - `Shared/TaskTitler.swift`: Apple Intelligence turns a long sentence into a title, a
    kind and a note; short text is the title as it is.
  - `software-factory` executable: `mcp` (the server over stdio), `status`, `tools`, `decide`.
- `App/Sources`:
  - `AppModel`: `@Observable @MainActor`; reloads the store every 2 s; every write goes
    through `persist`; starts `FactoryServer` on port 4747.
  - `FactoryServer`: `NWListener` on the port, one queue per connection (a request can
    block for minutes), Bonjour `_softwarefactory._tcp`.
  - `RootView` (split view: Floor, Resources, Factory, projects), `FactoryView` (gauges,
    verdict, what each kind of work would be told, the throttle sliders), `Notifier`
    (one banner per new question, options as actions; `Presence.isAtTheMac`), `FloorView` (stat tiles, Needs
    you as a horizontal strip, On the floor), `EscalationCard`, `ProjectView` (backlog
    with add, drag reorder, state menu, notes under rows), `ResourcesView` (add, slots,
    holders, Take back), `IntroSheet`, `SettingsView` (How it works on top, the register
    command, iCloud, the store, Developer in DEBUG).
- `Phone/Sources`: `PhoneModel` (NWBrowser finds the factory; `FactoryClient` speaks the
  package's HTTP over the Bonjour endpoint, polling `/api/snapshot` every 3 s and posting
  `/api/decide`; when the factory is out of reach it reads and decides through
  `CloudSync`), `PhoneRootView` (network primer in place, Needs you, On the floor),
  `PhoneBacklogView` (a project's backlog; add with the mic, near the Mac only),
  `PhoneIntroSheet`, `PhoneSettingsView`. Same bundle id as the Mac app.
- `Tools/make-icon.swift` draws both icon sets; `Tools/drive-mcp.py` drives the stdio server.

## Rules for changes

- A rule goes in the package with a test before it goes in a view.
- Never change a record's JSON shape without a reader for the old shape; bump
  `Records.version` when an older reader could not cope.
- Anything that runs on an audio or network thread is `@Sendable` and touches nothing
  main-actor: the dictation tap crashed once for exactly this.
- A new tool: add it to `Tool.all` and `call`, and a test in `MCPServerTests`.
- Every string a person reads follows `alex-writing-voice`; no em dashes.
- First-run: the sheet shows once (`hasSeenIntro`) and again from Settings. Reset with the
  Developer row or `defaults delete com.alexecollins.softwarefactory hasSeenIntro`.
- Try the floor with data: Settings ▸ Developer ▸ Add sample data, or drive the server by
  hand: `printf '...json-rpc...\n' | software-factory mcp`.
