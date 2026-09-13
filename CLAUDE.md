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
  -destination "platform=macOS" -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation -skipMacroValidation build
xcodebuild -project SoftwareFactory.xcodeproj -scheme SoftwareFactoryPhone -configuration Debug \
  -destination "generic/platform=iOS Simulator" -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation -skipMacroValidation build
cd Packages/SoftwareFactoryKit && swift test
open "build/DerivedData/Build/Products/Debug/Software Factory.app"
```

`-skipPackagePluginValidation -skipMacroValidation` are required, not optional: SwiftTerm
ships the `SwiftTermBuildInfoPlugin` build tool plugin, and without them Xcode fails the
build outright with "Validate plug-in SwiftTermBuildInfoPlugin in package swiftterm"
because nothing can answer its trust prompt from the command line.

Check `bash ~/.claude/skills/task-board/assets/machine.sh --brief` immediately before
`xcodebuild`; if the Mac is claimed, do not build.

## Shape

- `Packages/SoftwareFactoryKit` (Foundation only, `swift test`):
  - `Models`: `Project` (id is the folder path), `FactoryTask` (a task; named so because
    `Task` is Swift's; feature/bug/chore; backlog/inProgress/done/parked/blocked with a
    `Blocker` saying what on; rank), `Agent` (name, self-description,
    project, task, lastSeen, deregistered; working within 10 min of any call it made),
    `AgentMessage` (recipient, from, subject, contents, sent; private to the recipient's
    MCP inbox),
    `Escalation` (options, one recommended; `decide(_:by:)` records a `Decision`),
    `Resource` (slots, maxLease), `Lease` (one slot, one agent, until; `isActive(now:)`).
  - `FileStore`: one JSON file per record under `projects/`, `tasks/`, `escalations/`,
    `agents/`, `messages/`, `resources/`, `leases/`; atomic writes; unreadable files skipped. Tasks
    carry a short `number` (T509), unique across projects, given on add and settable
    (`task_number`); any `task_id` argument also takes "T509" or "509". A removed
    project (`project_remove`, or the header's Remove project) keeps its record with
    `removed` set and drops out of `load()` with its tasks; `loadEveryTask()` sees
    everything, so a number is never reused.
    `Snapshot` decodes with missing collections as empty, for older clients. `defaultRoot()` is the app group
    container or `$SOFTWARE_FACTORY_STORE`.
  - `Backlog`: order (in progress, backlog, parked, done), next rank, top rank, next
    task, move (onMove semantics; parked sits out), place above, state changes,
    `personMaySet` (backlog and parked only), current task, `visible`.
  - `Leases`: active leases, free slots, lease (renews if already held; full says when a
    slot frees), renew, release, heldBy, stale.
  - `CloudRecords`: each record as one CloudKit record (`json`, `updated`); diff for
    pushes; `decisionsToAdopt` for decisions made on another device.
  - `Projects`: `exact` (letters and digits only, case folded) and `nearMiss` (one name
    contains the other, a couple of characters apart, or a shared word of five letters:
    "NightSleeper" is a slip for "Sleeper Train"). `resolveProject` refuses a near miss
    unless `project_add` is called with `force`.
  - `AgentNumbers`: the agent numbers given out, one empty file each under
    `agent-numbers/`. Taking one is creating its file with O_EXCL, so the app and the
    server can both hand out names without talking to each other, and a deleted agent
    never gives its number back. `FileStore.takeAgentNumber()` seeds a store written
    before the folder existed from the numbers its agents already carry.
  - `LaunchPrompt`: the words an agent starts with, in one place: `project` (work the
    backlog), `task` (one task, already in its name, to claim), `free` (no project,
    the person says what for).
  - `Escalations.visible`: open questions in full, the newest three answered ones.
  - `Sweep.goneAgents`: an hour of silence and an agent is marked gone, leases released.
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
  - A project is a name (`Project(name:)`, id a UUID string; projects from before 12 Sep
    2026 keep their folder path as id). `resolveProject` takes a name, an id, or an old
    folder path (meaning the folder's name). On hold blocks no tool: every reply on that
    project ends with `MCPServer.holdWarning`.
  - `Shared/DictateField.swift`: a text field whose trailing control is a microphone
    while it is empty and the caller's own submit control once there is something to
    send. Tapping (Mac) or holding (phone) the microphone records; a popover above it
    shows the words live and throbs while listening; letting go settles them into the
    field. The primer and the denied and unavailable states live in the popover too.
    Not called from either add row as of 12 Sep 2026 (T91: it did not work well); the
    Mac and phone add rows are a plain `TextField` until it is revisited.
  - `Shared/TaskTitler.swift`: the first line of what was typed or dictated is the
    title; anything after it is the note. No model involved any more — Apple
    Intelligence's title extraction was unreliable enough to be worse than the words
    themselves.
  - `software-factory` executable: `mcp` (the server over stdio), `status`, `tools`, `decide`.
- `App/Sources`:
  - `AppModel`: `@Observable @MainActor`; reloads the store every 2 s; every write goes
    through `persist`; starts `FactoryServer` on port 4747.
  - `FactoryServer`: `NWListener` on the port, one queue per connection (a request can
    block for minutes), Bonjour `_softwarefactory._tcp`.
  - `RootView` (split view: Dashboard, Agents, Capacity, then the projects; a page per
    agent hangs off it), `DashboardView` (stat tiles, Needs you as a horizontal strip,
    the agents on the floor as cards; `AgentCard` is one of them and `AgentView` is the
    page behind it), `AgentsView` (every agent registered, and the button that starts a
    new one), `FactoryView` (the Capacity page: verdict and what each kind of work would
    be told, then one grid of cards for the Mac's own readings and every leasable
    resource alike, each a name and a colored utilization line; add a resource, see who
    holds it, Take back. The throttle sliders that held new work on swap or memory are
    out for the moment, to be refined),
    `Notifier` (one banner per new question, options as actions; `Presence.isAtTheMac`),
    `EscalationCard`, `ProjectView` (backlog
    with add, drag reorder, state menu, notes under rows, and Start an agent on this,
    on a backlog row: it reserves an agent, puts the task in its name and starts it on
    that one task), `AgentLauncher` and `StartAgent` (reserve, assign, launch: one path
    for every launch), `IntroSheet`, `SettingsView`
    (How it works on top, the register command, iCloud, the store, Developer in DEBUG).
  - `TerminalSessions` and `Tmux`: an agent the app launches runs in a terminal the app
    owns (SwiftTerm), so its page shows it working and you can type to it. tmux holds the
    session on a server of its own, so the agent outlives the app: quit, rebuild, come
    back, and opening its page attaches to what has been running all along. The person
    never sees tmux. Nothing asks tmux anything from the main thread: `TerminalSessions`
    keeps `held`, refreshed off it by `lookForHeldSessions()`, because running tmux while
    the window draws is a beachball.
  - The Mac app is **not sandboxed** (`com.apple.security.app-sandbox: false`). It has to
    start an agent in your own environment: `~/.claude`, the keychain, git, node, Xcode.
    A sandboxed child gets none of that. The cost is that this target cannot go to
    TestFlight or the Mac App Store as it stands; the iPhone app is unaffected.
- `Phone/Sources`: `PhoneModel` (NWBrowser finds the factory; `FactoryClient` speaks the
  package's HTTP over the Bonjour endpoint, polling `/api/snapshot` every 3 s and posting
  `/api/decide` and `/api/task`; when the factory is out of reach it reads, decides and
  adds tasks through `CloudSync` instead, so adding works anywhere iCloud does, not only
  on the Mac's own network; a task added that way carries no number until the Mac adopts
  it and gives it one), `PhoneRootView` (network primer in place, Needs you, On the floor),
  `PhoneBacklogView` (a project's backlog; type to add, anywhere iCloud reaches),
  `PhoneIntroSheet`, `PhoneSettingsView`, `PhoneNotifier` (a banner per new question
  with the options as actions; announced ids kept in UserDefaults so a cold launch by a
  push still knows what is news; the primer on the floor asks), `PhoneAppDelegate`
  (registers for remote notifications, saves the CloudKit query subscriptions through
  `CloudSync.subscribe()`, and on a silent push calls `PhoneModel.pushArrived()`, which
  is one `poll()`; `aps-environment` and `remote-notification` background mode are in
  `project.yml`), `LockScreen` (one Live Activity while a
  question is open; newest question, options as buttons; ended when none is open). Same
  bundle id as the Mac app.
- `Phone/Activity`: `FactoryActivityAttributes` and `DecideIntent`, compiled into both the
  app and the widget extension. The intent runs in the app and answers through
  `LockScreenDecider.handler`, which `PhoneModel.shared` installs.
- `Phone/Widgets`: the `SoftwareFactoryPhoneWidgets` extension (bundle id
  `com.alexecollins.softwarefactory.widgets`): the Lock Screen and Dynamic Island views.
  The Lock Screen gives an activity 160 points; the layout is sized for that.
- `Tools/make-icon.swift` draws both icon sets; `Tools/drive-mcp.py` drives the stdio server.

## Rules for changes

- A rule goes in the package with a test before it goes in a view.
- A terminal holds one agent. An agent registering into a session another agent holds
  takes it, and the factory clears it off the old record; an agent still live in there
  keeps it and the newcomer gets none (`Agents.claimSession`). A shell outlives its agent
  with SOFTWARE_FACTORY_SESSION still exported, which is how two used to share one window.
- An agent's number is its own for the life of the factory. `agent_register` takes an
  `agent_id` (the name the app told it to use); a name a live session is working as is
  refused, a name given out before is refused, and a name nobody has had is claimed.
  No other tool takes an `agent_id`: the connection says who is calling.
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
