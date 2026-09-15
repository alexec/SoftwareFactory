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
# The store build of the Mac app: the same sources, sandboxed. Swap Debug for
# Release-AppStore anywhere you would build the Mac app for the store.
cd Packages/SoftwareFactoryKit && swift test
# Restarting. `software-factory quit` ends the running app the way its own Quit menu
# item does, and says so; it waits for the process to go. Do not use
# `osascript -e 'tell application "Software Factory" to quit'`: from an agent's terminal
# it silently does nothing, which is how a day of work went on talking to yesterday's
# binary. (T271.)
OLD=$(pgrep -f "Software Factory.app/Contents/MacOS" | head -1)
swift run --package-path Packages/SoftwareFactoryKit software-factory quit
open "build/DerivedData/Build/Products/Debug/Software Factory.app"
pgrep -f "Software Factory.app/Contents/MacOS"   # must not be $OLD
```

**Why an AppleScript quit does nothing.** The app is not ignoring it. An agent's shell
belongs to a Background launchd session (`launchctl managername` says so), because the
tmux server holding the terminals was started outside the Aqua session. LaunchServices
cannot see a GUI app running from there, so AppleScript answers `application "Software
Factory" is running` with false, declines to launch an app just to quit it, and sends no
event at all, with no error to notice. `get name` still answers, off the bundle rather
than the process, so the app looks alive and deaf. An event addressed to the pid has
nobody to ask and quits it at once, which is what `software-factory quit` sends: the app
writes its own pid and start time to `app.json` in the store as it starts, and the CLI
reads that pair. Alex's own Cmd-Q, in the Aqua session, was never affected. (T271.)

`-skipPackagePluginValidation -skipMacroValidation` are required, not optional: SwiftTerm
ships the `SwiftTermBuildInfoPlugin` build tool plugin, and without them Xcode fails the
build outright with "Validate plug-in SwiftTermBuildInfoPlugin in package swiftterm"
because nothing can answer its trust prompt from the command line.

Check `bash ~/.claude/skills/task-board/assets/machine.sh --brief` immediately before
`xcodebuild`; if the Mac is claimed, do not build.

Rebuild and restart at the end of every task. The server on 4747 is the binary that is
running, not the tree: a new tool 404s until you quit and open the Debug app you just
built. tmux keeps the agents; they reconnect. Wait until
`curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4747/api/snapshot` is 200
**and the pid has changed**: a 200 from the app you meant to replace looks exactly the
same, and that is how a day of work went on talking to yesterday's binary. Build the phone too when the change is in it.

## Shape

- `Packages/SoftwareFactoryKit` (Foundation only, `swift test`):
  - `Models`: `Project` (a name; no description or instructions, T167), `FactoryTask` (a task; named so because
    `Task` is Swift's; work is design/plan/implement/fix/review/investigate/ship, default implement, shown as Code (T181); the first word of a title is the type; backlog/inProgress/done/parked/blocked with a
    `Blocker` saying what on; rank), `Agent` (number, terminal `title` from OSC 0/2,
    `bel` when it rang for a look,
    project, task, lastSeen, deregistered, `launchedWith` (which CLI the factory started
    it with, so a stopped one can be picked back up in the conversation that holds it),
    and the `pid` it reported with the
    `pidStartedAt` the factory read for it; working within 10 min of any call it made.
    Its `label` is its name everywhere: "A<n>", or its raw id for one that registered
    before numbers. There is no separate `name` field, and never should be again: it
    was always the label and the two could only ever drift, T158.
    How many may be on the floor is the person's to set, `Throttle.agentSlots` read
    through `Agents.cap(_:)`, eight by default and one to sixteen on the Capacity page:
    agents are slots handed out like any other resource (T209). On the floor means
    registered and not known to have exited. `agent_create` asks the factory to start
    another, which sets `wantsLaunch`; the app starts it. The one over the cap is
    refused. `agent_nudge` pokes another agent, sets
    `wantsNudge`, and the app types the same line as the person's Nudge),
    `AgentMessage` (recipient, from, subject, contents, sent, and `delivered` for records
    written before delivery existed; there is no inbox to read, `terminalLine` is
    what gets typed, and a nudge is simply a message whose contents are
    `LaunchPrompt.nudge`, so one path carries both. Once the app has typed one into the
    recipient's terminal it deletes the record: arrived is arrived, and a copy of what has
    landed is a pile rather than an inbox. `Mailbox` caps what is still waiting at three,
    and `message_send` and `agent_nudge` answer "Mailbox full" for the fourth; the
    person's own Nudge is never refused, and the person can throw any message away from
    the Messages panel. Alex, 14 Sep 2026),
    `Escalation` (options, one recommended; optional `link` to a document to review,
    filed as an artifact; optional `artifactID`; `decide(_:by:)` records a `Decision`),
    `Artifact` (a document on a project: title, body, optional link, and a `kind`.
    A note is the ordinary thing: a brief, a plan, a finding, matched on its title or its
    link, and twenty live ones is the cap (`Artifacts.cap`). Adding the same one again
    returns the one already there unless `replace` is passed. A status report is the one
    document an agent keeps about its own work: matched on the agent whatever it is
    called, always written over rather than added to, and outside the twenty, because
    there is only ever one per agent and a busy floor's reports would otherwise crowd out
    the project's own documents. `Artifacts.add` answers `created`, `replaced` or
    `alreadyThere`. A body is a kilobyte, `Artifacts.maxBody`: an artifact is read on a
    card while deciding what to do, not somewhere to put a transcript, and the refusal
    says to put the long one in the repo and file a link (T274). The factory asks an agent for one when an hour has gone by without
    it: `Sweep.statusReportsWanted` writes the message, `Agent.statusAskedAt` is how it
    knows not to ask twice, and a message still waiting in the mailbox stops it too,
    because asking again for something nobody has read is noise. T262, Alex, 15 Sep 2026),
    `Resource` (slots, maxLease), `Lease` (one slot, one agent, until; `isActive(now:)`).
  - `FileStore`: one JSON file per record under `projects/`, `tasks/`, `escalations/`,
    `artifacts/`, `agents/`, `messages/`, `resources/`, `leases/`; atomic writes; unreadable files skipped. Tasks
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
  - `LaunchAgent`: Claude Code, GitHub Copilot, Grok, Cursor or Terminal, chosen at
    launch. Terminal is not an agent: `isCodingAgent` is false, the command is `zsh -il`,
    there is no install link, no plugin command, no words to edit and no task assigned,
    and starting a stopped one is a new shell rather than a conversation picked back up.
    It is a shell in the project's folder that shows up on the floor like anything else,
    so you can run something by hand and watch it from the same page. `agent_create` never
    gets one, even when Terminal was the last pick. (Alex, 15 Sep 2026.) Grok's
    shell line is `grok --session-id <id> --always-approve --trust`: `--trust` grants
    folder trust for the launch directory (the project's folder), so project hooks,
    skills and MCP load without a prompt. The flag takes no path. (T180) Cursor is
    `cursor-agent --force --trust --approve-mcps` and takes no session id at all: it
    makes its own chat id, so the factory's session reaches it only in the words it
    starts with, which is where every tool call reads it from anyway. Resume is
    `--continue`, the newest chat in that folder, which is that agent's because a
    terminal holds one agent. (T206)
  - `Backlog.reminder`: an agent asking for a backlog is one moment from claiming
    something, so if it already has work in its name the list says so on the line above
    it. Otherwise it reads the list, likes the look of something, claims that too, and
    the task it forgot sits in progress with nobody on it until a person notices. Not
    when it asked for its own list with `mine`: it is looking at them. (T270.)
  - `WorkInProgress`: what is being worked on right now, on every project, for the In
    progress page. The floor says who is here and a project says what is left; this is
    the question between them, which used to mean opening every project in turn. A task
    in progress with nobody on it comes first and is marked, because an agent took it and
    then stopped or was deleted and nothing has come back to it since; that is also what
    the sidebar badge counts. (T287.)
  - `Escalations.visible`: open questions in full, the newest three answered ones.
  - `Artifacts`: live (not removed) documents on a project, newest first; `notes` and
    `statusReports` split them by kind, and `statusReport(by:on:)` is the one an agent
    keeps. `produced(by:)` is what one agent filed, its report first: a report keeps the
    date it was first filed however many times it is written over, so ordering everything
    by `added` would sink it further down its own page the longer it worked. Twenty is
    the cap on notes; adding the same title or the same link returns the one already
    there unless you replace it.
  - Two kinds of agent, and `Agent.isEmbedded` (it has a `session`) is the question.
    An embedded one the factory wrote down, named and started in a terminal it owns: its
    page shows it working, you can type to it, the factory can stop it, and tmux keeps it
    alive across a restart. An external one registered over MCP from wherever it already
    was; it does the same work and there is simply nothing here to watch or stop. Origin
    is not the same as having a terminal on screen: ours can be out of sight.
  - `ProcessCheck`: whether a process is alive, asked of the kernel. An agent reports
    its own `pid` off the pane it was launched into, and reads when that process started, because a pid on its own is recycled and
    the pair is what makes the answer trustworthy. `Agent.hasExited` is the question,
    and `Dashboard.AgentActivity.stopped` is how the floor says it. This is the one
    state silence could never tell you: a crashed agent and a thinking one are both
    quiet. Do not use `session` for this. It lives on the launch wrapper, so an agent
    that has been resumed has lost it while still working. An agent that never reported
    a pid is never called stopped: not seen is not dead.
    `ProcessCheck.stop` is how an agent is stopped, and it checks the pair before it
    signals anything: a pid on its own is recycled, so signalling one on its own is how
    you kill a stranger's work. SIGTERM first, then SIGKILL five seconds later for an
    agent that ignored it, because a Stop that leaves the agent working is worse than no
    Stop. `Agents.mayStop` and `Dashboard.AgentStatus.canStop` say who may be stopped:
    any agent whose process the factory knows and which has not already gone. An external
    agent never told us a process, so there is nothing here to stop. Stopping leaves the
    pane, so what the agent last said is still readable, and writes nothing down: the
    record reads as stopped on the next refresh, which is what hands back its leases and
    puts its task back. Delete stops it first. A deleted agent used to keep working with
    no card, no terminal and no way to reach it. (T261.)
  - `Agents.mayResume` and `StartAgent.resume`: a stopped agent is started back up in the
    same session, with the CLI it was launched with, so it comes back knowing who it is
    and what it was doing. Only for one the factory launched and then watched stop: an
    agent that never reported a pid is never called stopped, so it is never offered a
    start. The old tmux session is killed first, because `new-session -A` would attach to
    its dead pane and run nothing, and that kill runs off the main thread like every
    other question put to tmux. Start sits beside Stop on the agent's page and in both
    of its menus. (T262)
    Starting one types nothing into it. The conversation comes back on screen and stops
    there: what it does next is the person's to say, in the terminal or with Nudge.
    `TerminalSessions.Session.run` is a fresh id for each terminal actually started in a
    session, and the page keys its pane on that rather than on the session id, which does
    not change across a start: SwiftUI kept the view it had and went on drawing the dead
    terminal while the new one ran unseen. (Alex, 14 Sep 2026.)
  - `Sweep.stoppedAgents`: an agent whose process has gone gives back what it held. This
    replaced an hour of silence, which was a guess: an agent thinking is silent too.
  - `Sweep.unblocked`: a task blocked on a decision now made, or a task now done, goes
    back to the backlog with a line saying so. A block on a person clears by hand.
  - `Sweep.statusReportsWanted`: an agent at work is silent, and silence reads the same
    whether the work is going well or the agent is lost. So once an hour the factory asks
    the ones that have not said, with a message like any other. Nothing is asked of an
    agent in its first hour, one that filed or was asked within the hour, or one with mail
    still waiting. (T262.) The ask names what the report should say, because "how is it
    going" gets an essay from one agent and a shrug from the next: what is finished, what
    was decided, what it is waiting on Alex for, and where its questions stand. (T274.)
  - `StatusReportBoard`: every agent's report on one page, latest news first, with the
    agents that have said nothing at the bottom. Those rows are the point: an agent with
    no report is the one you most want to see, and leaving it out would make the page
    quietest exactly where something is wrong. `quiet(in:now:)` is the number on the
    sidebar badge. (T288.)
  - `Records.version` on every record; a decoder reads an older shape without it.
  - `Capacity`: `MachineReading` (`sample()` on macOS reads memory, swap, load, compiles,
    simulators through sysctl and Mach), `Throttle` (one file, `throttle.json`), the
    verdict, the reason, and `ask(work:)` for compile, simulator, model.
  - `Dashboard.make(snapshot:now:)`: counts, one `ProjectStatus` per project, one
    `AgentStatus` per agent on the floor.
  - `MCPServer`: JSON-RPC 2.0, `handle(_:)` is pure per request; `Tool.all` is the
    table; `call(_:_:)` does the work. `escalation_await` polls the store.
    `agent_create` writes the agent down and sets `wantsLaunch`; the person's own cap,
    read off the throttle, is what refuses the one over it.
    `agent_nudge` writes a message whose words are the nudge line; the app types every
    undelivered message into its agent's terminal, so nudges and messages are one path.
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
  - `Shared/MarkdownText.swift`: a document as a person reads it. `Markdown.blocks` in
    the kit splits headings, paragraphs, lists, quotes, fenced code and rules; the view
    draws them and leaves what is inside a line to `AttributedString`. Artifacts used one
    `AttributedString(markdown:)` call, which reads inline marks and drops every line
    break, so a whole plan arrived as one paragraph. (T208)
  - `Shared/WorkField.swift`: the add and edit field. The first word is the work
    (Design, Plan, Code, Fix, Review, Investigate, Ship); a matching word is offered
    while you type it. There is no picker. (T181)
  - `software-factory` executable: `mcp` (the server over stdio), `status`, `tools`,
    `decide`, `quit` (ends the running Mac app by addressing the quit event to its
    process, which is the only way that works from an agent's terminal, T271).
- `App/Sources`:
  - `AppModel`: `@Observable @MainActor`; reloads the store every 2 s; every write goes
    through `persist`; starts `FactoryServer` on port 4747.
  - `FactoryServer`: `NWListener` on the port, one queue per connection (a request can
    block for minutes), Bonjour `_softwarefactory._tcp`.
  - `RootView` (split view: Dashboard, Agents, Status reports, Capacity, No project, then the agents on
    the floor in a group of their own, then the projects. An agent is two lines: its dot
    and the project it is on, then what it is doing: the task it is on, else the first
    line of its status report, else the line it set with an OSC title
    (`AgentLine.underTheName`, T295). Its bell goes in front when it rang. The row opens that agent's page from anywhere, and opening the
    page clears the bell however you got there; right click to Nudge, Stop or Delete it.
    Stop is on the agent's page too, beside Nudge, and asks nothing
    before it acts: it used to, on the argument that one click ends an agent mid-thought,
    but Start picks the conversation back up, the pane keeps what it said and what it held
    goes back on its own, so the question was in front of something that undoes itself.
    (T261, then T294.)
    T222, T225, and Alex, 14 Sep 2026), `DashboardView` (stat tiles, Needs you as a horizontal strip,
    the agents on the floor as cards; `AgentCard` is one of them and `AgentView` is the
    page behind it; an agent that is not stopped has Nudge, its messages and terminal),
    `AgentsView` (every agent registered, and the button that starts a
    new one), `InProgressView` (every task underway on every project, the ones nobody is
    on at the top; the project name opens its backlog, T287), `StatusReportsView` (what everybody is doing on one page, off
    `StatusReportBoard`; an agent that has filed nothing says so rather than being left
    out, and a report past its hour has its age in orange. T288), `FactoryView` (the Capacity page: verdict and what each kind of work would
    be told, then one grid of cards for the Mac's own readings and every leasable
    resource alike, each a name and a colored utilization line; leasable cards show
    slots in use of the total, same shape as compiles; the
    Agents card is the same shape again and carries the stepper that sets how many may
    be on the floor at once; add a resource, see who holds it, Take back. The throttle sliders that held new work on swap or memory are
    out for the moment, to be refined),
    `Notifier` (one banner per new question, options as actions; `Presence.isAtTheMac`),
    `EscalationCard`, `ProjectView` (backlog
    with add, drag reorder, state menu, notes under rows, the artifacts the agents filed
    as cards in a grid (`ArtifactTile`, opening `ArtifactSheet`: they were disclosure rows
    down the middle of the backlog, which made a plan and a one-line note the same size
    and hid every one behind a triangle, T297),
    and Start an agent on this,
    on a backlog row: it reserves an agent, puts the task in its name and starts it on
    that one task), `AgentLauncher` and `StartAgent` (reserve, assign, launch: one path
    for every launch, including agents `agent_create` asked for), `LaunchChooser` (pick Claude Code, GitHub Copilot, Grok, Cursor or Terminal
    at launch, with that agent's install link and plugin command, then the words it will
    start with in a field you can edit and Reset, then Launch
    <name>. The words sit last, just above the button: they are the last thing you decide
    and they change with the agent picked above them (T273). It remembers the last pick, no preferred-agent setting. `LaunchPrompt.projectWork`
    and `taskWork` are what that field starts as, and the line naming the agent and its
    session goes in front of whatever it says, T260), `IntroSheet`, `SettingsView`
    (How it works on top, in-app vs Terminal, iCloud, the store, Developer in DEBUG).
  - `TerminalSessions` and `Tmux`: an agent the app launches runs in a terminal the app
    owns (SwiftTerm), so its page shows it working and you can type to it. tmux holds the
    session on a server of its own, so the agent outlives the app: quit, rebuild, come
    back, and opening its page attaches to what has been running all along. The person
    never sees tmux. OSC titles and BEL still reach SwiftTerm: the title is the line on
    the agent's card, and BEL sets `bel` until the page is opened. Neither reaches this
    app while nobody is attached, which is most of the time, so each has a second route.
    A title is state: tmux keeps the last one the pane set, so `Tmux.holding()` reads it
    beside the session names on the poll that was already running and `PaneTitles.parse`
    splits the two. A pane with no title is skipped rather than blanking the line a card
    already shows, which matters because a dead pane loses its title in tmux.
    (Alex, 15 Sep 2026.) The bell is drawn
    only on an agent that has rung, orange and wiggling, and nothing is drawn on the rest.
    It was on every agent, grey and quiet, so that it could be learned; with eight on the
    floor that is eight grey bells saying nothing, and the one that means something is
    harder to pick out among them, not easier (T289). tmux passes
    every bell through, `bell-action any` (Alex, 14 Sep 2026). The live path only hears a
    bell while this app is attached to that session, and most agents work with nobody
    looking, so the real route is a tmux hook: `alert-bell` runs `touch` on a file named
    after the session under `~/.local/state/software-factory/bells`, `Tmux.bellsRung()`
    reads that folder on every refresh and takes each mark away, and `AppModel.ring` sets
    `bel`. The hook fires with no client attached and fires again for the next bell, which
    the window's own bell flag does not: that flag sets once and nothing clears it without
    a client. Write the hook with no nested escapes, or tmux takes the line and sets an
    empty hook. (Alex, 15 Sep 2026.) A nudge, and any other
    message, is typed in with `sendLine`, which is two writes: the words, a gap, then the
    return. It answers whether there was a terminal to type into, and a message is marked
    delivered only when one took it. In one write
    the agent reads the lot as a paste and the return lands as a newline in its input box,
    so the nudge sat there unsent (Alex, 14 Sep 2026). Nothing asks tmux
    anything from the main thread: `TerminalSessions`
    keeps `held`, refreshed off it by `lookForHeldSessions()`, because running tmux while
    the window draws is a beachball.
  - The Mac app ships twice, from one set of sources, because the sandbox decides what it
    can do and the Mac App Store takes nothing but a sandboxed app (T163).
    - `Release` is the **direct download**: `com.apple.security.app-sandbox` false,
      Developer ID signed and notarised, exported with
      `AppStore/ExportOptions-macOS-direct.plist`. It can start an agent in your own
      environment: `~/.claude`, the keychain, git, node, Xcode.
    - `Release-AppStore` is the **store build**: the same sources with the sandbox on,
      exported with `AppStore/ExportOptions-macOS.plist` (or `-upload` to send it).
      Sandboxed, a child would inherit the sandbox and lose all of that, so the app does
      not pretend: `AgentLauncher.isSandboxed` is true and every launch point puts the
      command on the clipboard for you to paste into a window of your own. The floor, the
      MCP server on 4747, the backlogs, the questions and the phone all work as normal.
    - The two entitlements files, `App/SoftwareFactory.entitlements` and
      `App/SoftwareFactory-AppStore.entitlements`, are hand-written and must be kept in
      step. They are not generated from `project.yml` any more: xcodegen writes one file
      per target and would put the same one in every configuration.
    - The iPhone app is the same either way and archives from `Release`.
- `Phone/Sources`: `PhoneModel` (NWBrowser finds the factory; `FactoryClient` speaks the
  package's HTTP over the Bonjour endpoint, polling `/api/snapshot` every 3 s and posting
  `/api/decide` and `/api/task`; when the factory is out of reach it reads, decides and
  adds tasks through `CloudSync` instead, so adding works anywhere iCloud does, not only
  on the Mac's own network; a task added that way carries no number until the Mac adopts
  it and gives it one), `PhoneRootView` (network primer in place, Needs you, On the floor),
  `PhoneBacklogView` (a project's backlog; add, rank and park, anywhere iCloud reaches),
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
- **The session is the agent.** `Agent.id` is one UUID doing four jobs: the record's key,
  the name of the tmux session it runs in, the `--session-id` its CLI is launched with,
  and the `session_id` every MCP tool requires. The factory makes it before it launches
  anything, and the agent is told it in the words it starts with, not in the environment:
  an environment variable is lost when a conversation is resumed and the prompt is not.
  A terminal therefore cannot hold two agents, and there is no name to claim.
- **There is no registering and no goodbye.** The factory writes the agent down, names
  it, starts it with `exec` so the pane's process is the agent, and reads the pid off the
  pane. It knows the session, the name, the project and the process before the agent has
  said a word. An agent stops when its process stops, which the kernel answers and a
  crashed agent could never have told us; `Sweep.stoppedAgents` gives back what it held.
- The caller says who it is on every call. It used to be the connection, which drops when
  the app restarts while the agent works on, so an agent had to register again to get its
  own identity back and came back as somebody else.
- An agent's number is its own for the life of the factory.
- Never change a record's JSON shape without a reader for the old shape; bump
  `Records.version` when an older reader could not cope.
- Anything that runs on an audio or network thread is `@Sendable` and touches nothing
  main-actor: the dictation tap crashed once for exactly this.
- A new tool: add it to `Tool.all` and `call`, and a test in `MCPServerTests`.
- Every string a person reads follows `alex-writing-voice`; no em dashes.
- First-run: the sheet shows once (`hasSeenIntro`) and again from Settings. Reset with the
  Developer row or `defaults delete com.alexecollins.softwarefactory hasSeenIntro`.
- Rebuild and restart the Debug Mac app at the end of every task. The factory on 4747 is
  the running binary; until you quit and open the new one, the floor is yesterday's
  build. tmux holds the agents across the quit. Quit it with `software-factory quit`,
  never with an AppleScript quit, which does nothing from an agent's terminal (T271).
  Wait until 127.0.0.1:4747 answers 200 and the pid has changed, then mark the task done
  and take the next.
- Try the floor with data: Settings ▸ Developer ▸ Add sample data, or drive the server by
  hand: `printf '...json-rpc...\n' | software-factory mcp`.
