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
# `swift build` here also makes `software-factory`, which is the agent daemon the app
# spawns for anything speaking ACP. A Debug app finds it in this checkout's build output;
# without it, Settings says so and no ACP agent can start. (T373.)
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
    `LaunchPrompt.nudge`, so one path carries both. A nudge says "The user has nudged you
    to continue your work" and nothing about how to do the job: it used to name the
    backlog and the next task nobody is on, which is the factory instructing an agent that
    already has its own instructions and may be mid-something the backlog says nothing
    about (T370). `LaunchPrompt.pokes` are the lines the factory types in itself, the
    nudge and `carryOn`; `AgentMessage.isPoke` is what puts them in bare, because they
    already say a person asked. Everything else is attributed. Once the app has typed one into the
    recipient's terminal it deletes the record: arrived is arrived, and a copy of what has
    landed is a pile rather than an inbox. `Mailbox` caps what is still waiting at three,
    and `message_send` and `agent_nudge` answer "Mailbox full" for the fourth; the
    person's own Nudge is never refused, and the person can throw any message away from
    the Messages panel. Alex, 14 Sep 2026),
    `Escalation` (options, one recommended; optional `link` to a document to review,
    filed as an artifact; optional `artifactID`; `decide(_:by:)` records a `Decision`),
    `Artifact` (a document on a project: title, body, optional link, and a `kind`.
    A document is one of three things, which is what `Artifact.source` answers: the
    markdown body an agent typed, a page on the web, or a markdown or HTML file on this
    Mac. What somebody wrote wins, so a document with a body is its body and its link is
    a reference beside it. `Artifacts.validatedLink` is what may be filed: an http or
    https URL as typed, which covers a server the agent has running here; or a file path
    stored absolute with the tilde off, against the real home rather than
    `NSHomeDirectory`; relative is refused for the same reason a project's folder cannot
    be relative. `Artifacts.readableFiles` are the ones put on paper, markdown and HTML;
    `pictureFiles` are shown as themselves, images and PDFs, because a screenshot with
    margins around it is a screenshot you can see less of, and a page of prose saying
    what the screen looked like is not the screen (T317). Anything else is refused rather
    than filed and then shown as nothing. (T311.)
    A note is the ordinary thing: a brief, a plan, a finding, matched on its title or its
    link, and twenty live ones is the cap (`Artifacts.cap`). Adding the same one again
    returns the one already there unless `replace` is passed. A status report is the one
    document an agent keeps about its own work: matched on the agent whatever it is
    called, always written over rather than added to, and outside the twenty, because
    there is only ever one per agent and a busy floor's reports would otherwise crowd out
    the project's own documents. `Artifacts.add` answers `created`, `replaced` or
    `alreadyThere`. Deleting an agent deletes its status reports with it,
    `Artifacts.statusReports(by:)`, off the disk rather than marked removed: the report
    is about the agent, and with the agent gone it is a report by nobody. Its notes stay,
    because a plan or a finding belongs to the project and is still true whoever wrote it
    (T310). A document arrives unread and `Artifacts.read` marks it read when the person
    opens it, which is `ArtifactPaper` appearing, the one place a document is shown whole.
    Writing one over makes it unread again, unless the new words are the old words: an
    agent that has rewritten its status report has something to say. A read card is
    smaller with one line of preview rather than three, and an unread one carries a dot,
    on the project's cards and on the agent's tabs alike. Not greyed: greying and
    shrinking say the same thing twice, and grey also says you cannot have it (T335).
    A body is a kilobyte, `Artifacts.maxBody`: an artifact is read on a
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
  - `Projects.folder`: a project's path as something that can be opened, the other half
    of `shortPath`. The tilde the person was shown comes off again, against the real home
    rather than `NSHomeDirectory`, which in the sandbox is our own container. Anything
    that is not absolute is no folder at all: `URL(filePath:)` reads it against the
    working directory, which is wherever the app was launched from, and would open a
    folder nobody meant. (T300.)
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
  - `LaunchAgent`: Claude Code, GitHub Copilot, Grok or Cursor, chosen at launch. A plain
    shell used to be a fifth and never was one: it registered with nothing, was told
    nothing, held no task and had no conversation to resume, so every question asked of
    this type had to be answered "except for that one". A terminal is opened **beside** an
    agent now, in the same folder, which is what it was always for. See `AgentShells`.
    (Alex, 16 Sep 2026.) Grok's
    shell line is `grok --session-id <id> --always-approve --trust`: `--trust` grants
    folder trust for the launch directory (the project's folder), so project hooks,
    skills and MCP load without a prompt. The flag takes no path. (T180) Cursor is
    `cursor-agent --force --trust --approve-mcps` and takes no session id at all: it
    makes its own chat id, so the factory's session reaches it only in the words it
    starts with, which is where every tool call reads it from anyway. Resume is
    `--continue`, the newest chat in that folder, which is that agent's because a
    terminal holds one agent. (T206)
  - `ACP` and `ACPTranscript`: the Agent Client Protocol, from the client's side. JSON-RPC
    2.0 over a pipe, the same wire `MCPServer` speaks pointed the other way: there we
    answer an agent, here we drive one. We declare no filesystem and no terminal
    capability, because these agents are local CLIs standing in the project's folder with
    their own file tools and their own shell, and that drops a third of the protocol.
    The shapes are taken off the wire rather than out of the documentation, which is wrong
    where it matters: a permission outcome is `selected` and not `Approved`, a turn ends
    `end_turn` and not `Completed`, and `headers` must be present and empty on an http MCP
    server or the agent answers "Invalid params" without saying which field it meant. Both
    test fixtures are real recordings, one of `copilot --acp` and one of
    `claude-agent-acp`, because the two do not send the same shapes: a tool call's
    `content` is a list and a message chunk's is an object.
    `ACPTranscript` is the fold, and the fold is the point: an agent says one sentence as
    eighteen one-word chunks, and a page that draws eighteen rows is not showing you a
    sentence. It lands a `tool_call_update` on the call that started it without wiping its
    title, and answers what the OSC title used to guess at: what it is doing now, what it
    last said, which files it has actually changed, how full its context is. `ACPHeadline`
    answers the one-line version and never grows, which is what the daemon keeps for
    sixteen agents rather than sixteen whole conversations. (T373.)
  - `AgentDaemon`, `AgentFloor`, `ACPConnection`, `AgentSocket`, and
    `software-factory agentd`: the process holder. **An ACP agent is a subprocess of its
    client and dies with it**, and this app is rebuilt a dozen times a day, so the app is
    not the client. The daemon is. It is a far smaller thing than tmux and that is the
    argument for owning it: tmux is a terminal multiplexer, with ptys, ANSI, scrollback
    and resize, and under ACP there is a pipe with JSON going along it.
    **The stream is not on the socket.** Every line goes to `transcripts/<agent>.jsonl`
    under the store, beside `agents/` and `tasks/`, and the app folds that file the way it
    reads every other record; the socket carries commands and state, one request per
    connection, no subscription. The durable thing was a file either way, and a socket
    that also streams is a second copy of the truth that can disagree with the first.
    Stderr goes to `<agent>.err`, which is the only thing that says why an agent would not
    start. A unix socket under `~/.local/state/software-factory`, not under the store: the
    path is capped at 104 characters and a group container spends most of that.
    `ACPConnection` is deliberately not an actor. Lines are written down in the order they
    arrive, and actor hops are not ordered, so the reading, the buffering and the
    appending all happen on the pipe's own serial queue, through one file handle: two
    handles on one file each keep their own offset, and that is how every prompt went
    missing from the log once. (T373.)
  - `Agent.runtime` is `terminal`, `acp` or `external`. **All four coding agents speak
    ACP**, each behind a different word: `claude-agent-acp` (Zed's adapter, the one you
    install, `npm i -g @agentclientprotocol/claude-agent-acp`), `copilot --acp`,
    `grok agent stdio`, `cursor-agent acp`. Grok is the most forthcoming, reporting
    `resume` as well as `loadSession`; Cursor has `loadSession` only, so Start replays
    rather than picking up where it left off, which still closes T206 because it is the
    protocol answering rather than `--continue` and a guess about which chat was this
    agent's. Only Terminal does not speak it, because a shell has nothing to say.
    Checked by handshaking with each binary rather than by grepping its help, which found
    two of them and missed the two that put it behind a subcommand. (Alex, 16 Sep 2026.)
    The terminal path stays for the Terminal kind, for the Runs in Terminal setting, and
    for the sandboxed build, which is a separate feature from how an agent runs. `Agent.acpSession` is the id the agent minted for itself:
    `Agent.id` is still the record's key and still what the agent signs its factory calls
    with, which is two ids rather than one, the compromise Cursor already forced in T206.
  - **Nothing is said to an agent in the middle of a turn.** Measured on all four rather
    than read: Claude Code and Grok queue a prompt that arrives mid-turn and answer both,
    Copilot drops it without a word, and Cursor cancels the turn in flight to take the new
    one. Half and half, which is the worst possible split: it would have worked every time
    anybody tried it by hand. Our
    code called all three a success and deleted the message from the mailbox, so a nudge to
    a busy Copilot agent vanished and a nudge to a busy Cursor agent would have thrown away
    its work. `AgentFloor` queues instead, sends one at a time as the agent frees up, and
    `Running.queued` says how many are waiting. A stopped agent gives up its queue: there
    is nobody to say it to, and it must not be said to whatever starts next under that
    name. (T373.)
  - `ACP.ToolCall.heading` is what a tool call's row says, and it is not just `title`.
    A call's first message often carries the raw tool name, `read_file` or `apply_patch`,
    and only the update that follows replaces it with a sentence, so the row reads like a
    function reference for as long as the call is running, which is exactly when somebody
    is looking at it. Grok never sends anything else, because its calls carry no kind
    either. And all of them write absolute paths, so a row is nine tenths somebody's home
    folder. A title written for a person keeps its words and loses its paths; a bare tool
    name becomes a verb and the file it is working on, off `locations`.
    (Alex, 16 Sep 2026.)
  - There is nothing to register any more. `LaunchAgent.setupCommand` and the
    `claude plugin marketplace add` dance are gone: `session/new` carries the factory's MCP
    server and all four coding agents speak ACP, so an agent is handed its tools as it
    starts. `setUp` is what is left, and the only thing in it is Zed's adapter for Claude
    Code. (T373.)
  - The factory does not ask an agent it can watch how its work is going.
    `Sweep.statusReportsWanted` skips an ACP agent: the ask exists because an agent at work
    is silent and silence says nothing about how it is going, and an ACP agent is not
    silent. Its page shows the work and `StatusReportBoard.Row.doing` shows the same line
    on the board, so such a row is never stale and never chased. What a report says that a
    transcript cannot is judgement, and an agent with something to say files one without
    being asked. `Sweep.idleAgentsToStop` takes `working`, the agents the daemon says have
    a turn in flight, which is the real answer where the rest of that rule is a proxy:
    stopping an agent mid-turn throws the turn away. (T373.)
  - `AgentProfile` and `LaunchAgent.profile`: what each agent was measured doing, as
    opposed to what it says it can do. ACP describes the shape of a message and almost
    nothing about the behaviour behind it, and a capability flag is no help either, because
    Cursor declares `loadSession` and then refuses `session/load`. So the factory keeps its
    own notes and the app reads them: `Agents.mayResume` asks the profile, so a stopped
    Cursor agent is not offered a Start that would fail, and `Agents.whyNoResume` says why
    in its place. Not a disabled button: a control that can never work on this agent says
    come back later, and later never comes. Every answer is yes, no or **not tried**, three
    rather than two, because writing "we have not tried it" down as "no" quietly takes a
    feature away from an agent that has it. The help window shows the notes, and the
    caveats, per agent. (T373.)
  - What each agent can actually do, measured through the daemon on 16 Sep 2026. All four
    handshake, make a session, take a prompt and are handed the factory's MCP server over
    http, which is the plugin install gone: the underlying CLI is launched with
    `--mcp-config {"mcpServers":{"software-factory":{"type":"http","url":"http://127.0.0.1:4747/mcp"}}}`.
    Claude Code and Grok are both proven all the way through a piece of work: tool calls,
    a diff, a stop and a start that came back knowing what it had made. Two things are
    only true of Grok: it never asks before it changes something, so nothing it does will
    ever reach the person as a question, and its tool calls carry a name but no `kind`, so
    `ToolCall.Kind.changesAnything` never speaks for it and its rows fall back to what it
    called the tool. Cursor declares `loadSession` and then answers `session/load` with
    "Invalid params", so Start on a stopped Cursor agent does not work, and its account
    needs a plan before it will do anything here.
  - Three things keep the rest of the floor from having to know ACP from tmux. The
    daemon's `Running.line` goes into `Agent.title`, which every card, sidebar row and
    status board already reads, so the OSC title retired without a view changing. The
    daemon reports the agent's pid and the app writes it down as it always did, so
    `hasExited`, `Agents.mayStop`, `mayResume` and `Sweep.stoppedAgents` go on asking the
    kernel. And `AgentMessage.promptLine`, which was `terminalLine`, is the one line the
    factory gives an agent whatever holds it: typed into a pty for one, `session/prompt`
    for the other. The name stopped being true the day half the floor had no terminal.
  - `Backlog.reminder`: an agent asking for a backlog is one moment from claiming
    something, so if it already has work in its name the list says so on the line above
    it. Otherwise it reads the list, likes the look of something, claims that too, and
    the task it forgot sits in progress with nobody on it until a person notices. Not
    when it asked for its own list with `mine`: it is looking at them. (T270.)
  - `Waiting`: what the factory is holding that has not reached anybody, the two counts
    beside its own name in the title bar: documents nobody has opened
    (`unreadDocuments`) and messages not yet typed into a terminal (`messages`). Both are
    quiet by nature, a document landing on a project you are not looking at and a message
    waiting for an agent whose terminal is off screen, so neither has a page of its own
    to say so from. Only live things count: a document on a removed project and a message
    to a deleted agent are never going to reach anybody, and a number that can only go up
    is one people learn to ignore. Nothing is drawn when nothing is waiting, the way the
    bell is nothing until an agent rings it. (T373.)
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
    Starting one types `LaunchPrompt.carryOn` into it, as a message like any other so it
    lands when the new terminal appears. It used to type nothing, on the argument that a
    factory putting words in an agent's mouth the moment it wakes is one you cannot start
    without committing to; what that gave instead was an agent sitting at a prompt doing
    nothing until somebody noticed and nudged it, which is the same commitment made twice
    (T364, and Alex 14 Sep 2026 the other way).
    `TerminalSessions.Session.run` is a fresh id for each terminal actually started in a
    session, and the page keys its pane on that rather than on the session id, which does
    not change across a start: SwiftUI kept the view it had and went on drawing the dead
    terminal while the new one ran unseen. (Alex, 14 Sep 2026.)
  - `Sweep.stoppedAgents`: an agent whose process has gone gives back what it held. This
    replaced an hour of silence, which was a guess: an agent thinking is silent too.
  - `Sweep.idleAgentsToStop`: an agent with nothing to do and nothing coming is stopped
    after an hour, `Sweep.idleStandsFor`. Nothing to do means all four: no task of its own
    in progress or blocked, no question of its own open, nothing on its project's backlog,
    and no mail waiting. Each is a way of being busy that looks like silence. The hour runs
    from the last task it touched, not from `lastSeen`, which a polling agent keeps fresh
    while doing nothing. An agent on no project is left alone: there is no backlog to be
    empty. Safe to do unasked because Start picks the conversation back up (T357).
  - `Sweep.agentsToPoke`: work landing on a project where nobody is working nudges the
    first agent by number. Only when every agent on that project is idle: one that is on
    a task will read the backlog when it finishes, and poking it now interrupts work to
    tell it about work. The transition is what counts, so it fires once however the task
    arrived, and an agent with mail already waiting is left alone (T352).
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
  - **An agent is reached at its own address.** `session/new` hands each ACP agent
    `http://127.0.0.1:4747/mcp/<its id>`, so the factory knows who is calling from where
    the call arrived and the agent never says. `session_id` comes off all thirty-three
    tools for it, and `LaunchPrompt.youAreNamed` drops the sentence that told it an id and
    asked it to keep one. An external agent has no such address, calls `/mcp` and passes
    `session_id` exactly as before, which is why the argument still exists. A call at an
    agent's address needs no `Mcp-Session-Id` either: the address is the identity, and a
    transport session is something any caller can ask for. The tool list can differ per
    agent for the same reason: one that asks through the protocol is not offered
    `escalation_raise` or `escalation_await`, because it has a better way and the factory
    should not offer a second. (T373.)
  - `Throttle.permissions` has four positions, and `agentDecides` is the one to know:
    the agent judges each call itself and stops only when it thinks it should, which is a
    different thing from being told yes to everything. Every one of these CLIs offers
    both, and Claude Code's words for them are `auto`, "Claude handles permission
    decisions", and `bypassPermissions`, "Accepts all permissions". An agent with no such
    mode is told yes by the factory, which is the nearest thing it has. The stance is read
    as a string and matched rather than decoded as the enum: a value a later version wrote
    would otherwise fail the whole record and take the agent cap down with it.
    **It is the floor's setting, not the last word.** An agent's own page has a menu of
    exactly the modes that agent offers, in its own words, and picking one there stops that
    agent following the floor: one on a repo you care about asking while one on a scratch
    project gets on with it is the ordinary case, not a conflict. Nothing is drawn for an
    agent that offers no modes, which is Grok. (Alex, 16 Sep 2026.)
  - `Throttle.permissions` also picks the agent's **session mode**, where it has one.
    Claude Code offers `bypassPermissions`, "Accepts all permissions", which is what every
    agent was launched with before ACP; `ACP.Modes.wanted` takes the most permissive on
    offer when the person has said to let agents get on with it, and puts it back to
    `default` when they have not. The daemon follows a change in Settings on its next
    `list`. Copilot's modes are about how it converses and Grok has none, so for those the
    factory answers their requests instead, and it answers `allow_always` rather than
    `allow_once`: the person decided in advance, so it is a standing decision and one
    round trip rather than one per call. `allow_once` is still what nobody-answered takes,
    because that is the case where no decision was made on purpose. (Alex, 16 Sep 2026.)
  - `HTTP`: `HTTPRequest.parse`, `HTTPResponse.serialized`, and `HTTPRouter` (`POST /mcp`,
    `GET /api/snapshot`, `POST /api/decide`, `POST /api/task`; browser origins refused).
  - `SampleData`: records for a Debug build to look at.
  - `Shared/CloudSync.swift` (both apps, not the package): the CloudKit calls. Container
    `iCloud.com.alexecollins.softwarefactory`, private database, query on `updated`.
  - `Shared/Dictation.swift`: `SpeechAnalyzer` on device; `volatile` and `settled` text.
  - `Spoken` and `App/Sources/DictateButton.swift`: talking to the factory. One view, not
    two: the project on the top line, the task in the middle, Add at the bottom, and it
    goes on listening the whole time. It used to listen on one screen and show what it
    understood on another, so you spoke to a box that was about to be replaced and a
    second thought after the pause had nowhere to go, because it had stopped listening.
    Words land in the task as they settle (`Spoken.appended`, added rather than written
    over, so a correction typed into the field survives the next sentence), and the words
    still being recognised land there too: `Spoken.live` puts them on the end as a tail
    and the next revision replaces that tail rather than saying it twice, so what has
    settled and anything typed sit in front of it untouched. They used to sit in grey
    under the field, which kept the field still and meant reading your own sentence in
    two places, the half you were watching being the half you could not touch (T372). A pause files nothing: it
    is where `Spoken.settling` reads the project out of what was said and takes the naming
    of it out of the task. Naming a project wins over the page you are looking at, on the
    second sentence as much as the first. Add files it and keeps listening, so the next
    thing you say is the next task. `Spoken.filing` splits it: first sentence the title,
    the whole of it in the note, a line break winning over a full stop. (T363, was T340.)
  - A project is a name (`Project(name:)`, id a UUID string; projects from before 12 Sep
    2026 keep their folder path as id). `resolveProject` takes a name, an id, or an old
    folder path (meaning the folder's name). Putting a project on hold stops the agents
    on it, `Sweep.agentsHeld`, however the hold was set: the Active toggle or
    `project_set`. It is the transition that stops them rather than the state, so an
    agent started on a held project on purpose is left alone, and Start picks up each
    stopped one where it left off (T309). On hold blocks no tool: every reply on that
    project ends with `MCPServer.holdWarning`, which is all an external agent gets,
    because the factory never knew its process and has nothing to stop.
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
  - `Shared/MarkdownText.swift`: markdown as text views, for a line or two inside a row:
    a status report on the Status reports page, a document on the phone. `Markdown.blocks`
    in the kit splits headings, paragraphs, lists, quotes, fenced code and rules; the view
    draws them and leaves what is inside a line to `AttributedString`. Artifacts used one
    `AttributedString(markdown:)` call, which reads inline marks and drops every line
    break, so a whole plan arrived as one paragraph. (T208) A line indented under a
    bullet is the rest of that bullet: a hard-wrapped list used to come apart, half the
    sentence in the item and half underneath it as a paragraph. (T311)
  - `Paper.Tone` and `Shared/PaperTone.swift`: the house theme. A warm near-white ground,
    a warm near-black ink, and one rust mark. Seven colours and a measure, written down
    once, with the stylesheet built from them: the documents are HTML in a web view and
    the agent's conversation is SwiftUI, so two sources drift the first time either is
    touched.
    Three other palettes were tried on the way here, and this is the one Alex picked with
    all of them in front of him: cool drafting paper read as technical rather than
    readable, and buff manila came out too orange. It is close to what Claude itself is
    set on, and that was raised, weighed and settled rather than overlooked, so leave it
    alone. The tests guard what is worth guarding now: every tone is warm, the mark is a
    colour rather than a second black, and dark is its own paper rather than a white page
    dimmed.
    **It goes under the whole app**: the window, the sidebar, Settings, the sheets, and
    the rust is the app's tint so every control picks it up. Liquid Glass keeps its own
    translucency and sits on the paper rather than replacing it, so the theme is what
    shows through the glass instead of a second idea beside it. The sidebar and Settings
    hide their own scroll backgrounds to let it through. (Alex, 16 Sep 2026: use it
    everywhere. Asked for twice, taken away once in between, and this is the settled
    answer.)
  - An agent's conversation is set on paper: the warm ground, a serif for everything
    anybody said, the same measure the documents use so a line is one you can read to the
    end of, and no gloss anywhere. A tool call is a block set into the page, like a quote
    or a piece of code, rather than a card sitting on top of it. What the agent is doing
    stays plain, because the paper is for the words.
  - `Paper` in the kit, and `App/Sources/ArtifactPaper.swift`: a document to read, as a
    page. `Paper.html` turns the blocks into HTML and `Paper.page` puts it on paper: a
    warm ground, a serif, a measure, light and dark. `ArtifactPaper` shows all three
    kinds of document in one `WKWebView`: markdown this app rendered, an HTML file loaded
    from where it sits, a website as itself. Script is off for anything this app
    rendered and on for a website, and a link the person clicks opens in their browser
    rather than taking the pane somewhere else. Reading a file needs the sandbox off, so
    the store build says it could not read it rather than showing a blank page. (T311)
  - `Shared/WorkField.swift`: the add and edit field. The first word is the work
    (Design, Plan, Code, Fix, Review, Investigate, Ship). There is no picker and nothing
    is offered while you type: a row of words under the field is something to read and
    dismiss on every task you add, and the first word is either one of seven or it is
    Code. `FactoryTask.Work.completions` went with it. (T181, then T366.)
  - `software-factory` executable: `mcp` (the server over stdio), `status`, `tools`,
    `decide`, `quit` (ends the running Mac app by addressing the quit event to its
    process, which is the only way that works from an agent's terminal, T271).
- `App/Sources`:
  - `AppModel`: `@Observable @MainActor`; reloads the store every 2 s; every write goes
    through `persist`; starts `FactoryServer` on port 4747.
  - `FactoryServer`: `NWListener` on the port, one queue per connection (a request can
    block for minutes), Bonjour `_softwarefactory._tcp`.
  - `RootView` (split view: Dashboard, Capacity, No project,
    then the projects, each with the agents on it hanging underneath, working ones first and
    stopped ones after (`Dashboard.agents(on:)`, T359). They were a flat Agents section and
    a Stopped one, which meant reading every row's project name to find the two on the
    thing you came for; an agent belongs to the work it is doing. Agents on no project hang
    under the No project row the same way. A project row is its name, how many tasks
    are on its backlog in grey, and a count in orange when it has a question waiting. The
    dot and the counts of blocked and in progress came off in T358: a sidebar is a list of
    places to go, and a row that also reports on the work makes you read twelve small
    numbers to find the project you were looking for. The backlog count is back because it
    answers a different question, not how the work is going but where there is work left to
    pick up, and it sits quiet and to the left so the question still reads first.
    (Alex, 16 Sep 2026.) An agent is its name and dot, then a line
    for every task in its name, numbered (`AgentLine.linesUnderTheName`, off
    `Backlog.alreadyYours`, blocked first). It showed the one task the factory calls
    current, which for an agent holding three is two thirds of a lie: the rest are in its
    name, nobody else may take them, and its own page was the only place to see them
    (T362). An agent holding nothing says what it can for itself instead: the first line
    of its status report, else the line it set with an OSC title
    (`AgentLine.underTheName`, T295). Its bell goes in front when it rang. The row opens that agent's page from anywhere, and opening the
    page clears the bell however you got there; right click to Nudge, Stop or Delete it.
    Stop is on the agent's page too, beside Nudge, and asks nothing
    before it acts: it used to, on the argument that one click ends an agent mid-thought,
    but Start picks the conversation back up, the pane keeps what it said and what it held
    goes back on its own, so the question was in front of something that undoes itself.
    (T261, then T294.)
    T222, T225, and Alex, 14 Sep 2026), `DashboardView` (stat tiles, Needs you as a horizontal strip,
    the agents on the floor as cards; `AgentCard` is one of them and `AgentView` is the
    page behind it; an agent that is not stopped has Nudge, its messages and terminal.
    That page is a band and two columns. The band sits under the agent's name, full
    width, and says what it is on, what it holds, its messages and what it is running
    with; not its pid and not its session id, which look useful and are not (T331). It
    was a column, which made four with the sidebar, and then the terminal's footer, which
    read as being about the terminal (T314, T332). The columns are the terminal and what
    the agent has written, with a draggable divider between them whose width is
    remembered across launches (`ColumnGrip`, T329). The documents column is its status
    report and its notes, one on paper at a time, chosen from tabs across the top that
    scroll and scroll the current one into view (`DocumentTabs`, T330); a menu showed one
    name and hid the rest. It is not drawn at all for an agent that has written nothing,
    and the band and the column each have a toolbar toggle. They were rows behind a
    triangle, which is a fine way to list documents and no way to read one, T311),
    `AgentsView` and `StatusReportsView` (every agent registered; everybody's
    report on one page). Both came off the sidebar in T360 and neither has another way in
    yet, so they are pages with no door: say whether they should go or get one. Starting
    an agent on no project did not go with them, `FreeAgentCard` moved to the No project
    page, which was the only other place such an agent could have come from. The In
    progress page went further in T365 and is gone altogether, the view, `WorkInProgress`
    and its tests: the floor says who is here and a project's backlog says what is left,
    which between them is the whole of what that page answered,
    `StatusReportsView` (what everybody is doing on one page, off
    `StatusReportBoard`; an agent that has filed nothing says so rather than being left
    out, and a report past its hour has its age in orange. T288), `FactoryView` (the Capacity page: verdict and what each kind of work would
    be told, then one grid of cards for the Mac's own readings and every leasable
    resource alike, each a name and a colored utilization line; leasable cards show
    slots in use of the total, same shape as compiles; the
    Agents card is the same shape again and carries the stepper that sets how many may
    be on the floor at once; add a resource, see who holds it, Take back. The throttle sliders that held new work on swap or memory are
    out for the moment, to be refined),
    `Notifier` (one banner per new question, options as actions; `Presence.isAtTheMac`),
    `EscalationCard`, `OpenFolder` and
    `OpenFolderButton` (the project's folder in the Finder, from its own header where the
    path itself opens it and Change sets it, and from the agent page beside the project
    name, T300), `ProjectView` (backlog
    with add, drag reorder, state menu, notes under rows, and the documents in a column of
    their own beside it: the same `ArtifactBrowser` the agent page uses, with a
    `ColumnGrip` between them whose width is remembered, which with the sidebar is three
    columns (T342, T349). They were cards in a grid opening a sheet, and before that
    disclosure rows down the middle of the backlog (T297); reading matter does not belong
    in the same scroller as a list of work.
    And Start an agent on this,
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
  - `AgentShells` and `App/Sources/AgentShells.swift`: the terminals a person has opened
    beside an agent, in that agent's folder, as tabs. Two small icons sit above the
    agent's columns, one for what it has written and one for a shell, and they choose what
    the side column shows: only one can be showing, and a pair of toggles would say
    otherwise. Clicking the terminal icon with none open gives you one, because that is
    what clicking a terminal icon means. A shell is `zsh -il` and nothing is typed into it:
    a terminal that opens with somebody else's instructions in it is a terminal pretending
    to be an agent. They go when the agent is deleted. Clicking the terminal icon opens
    one rather than offering to: a pane with a button saying Open a shell is the pane
    asking you to confirm the thing you just asked for. A shell always has somewhere to
    start, the project's folder or your home, so the icon is never a dead end.
    (Alex, 16 Sep 2026.)
  - `Floor` and `App/Sources/AgentTranscriptView.swift`: the app's side of the daemon, and
    what an ACP agent's page is instead of a terminal. `Floor` starts the daemon when
    nothing is answering, asks what it is holding on a clock of its own, and folds
    transcripts off disk for the pages that are open and no others. Every call to it goes
    off the main thread, for the reason tmux taught us.
    The page is turns, tool calls with a state each, diffs drawn as diffs with their
    counts, and the plan as a row of chips that tick themselves off.
    **Only the most recent tool call of a run is drawn**, `ACPTranscript.page`, and the
    card says how many went before it. An agent reads four files and searches twice before
    it writes anything, and a dozen finished cards buried the two things worth reading:
    what it said, and what it is doing now. Making each one smaller was the wrong fix,
    because the problem was how many there were rather than how big each was. Thinking is
    dropped before the grouping rather than after, or a thought between two tool calls
    splits one run into two. (Alex, 16 Sep 2026.) Thinking is folded
    away behind a button, because it is nine tenths of the words and a tenth of the
    interest. The field at the bottom is `session/prompt` and goes straight to the agent
    rather than through the mailbox: this is a person typing on the agent's own page,
    which is what the terminal was, and the terminal never queued. The mailbox and its cap
    of three are for messages from other agents. (T373.)
  - `Throttle.permissions`, on the Asking section of Settings: how much an agent may do
    without stopping to ask. Before ACP every agent was launched with its own auto-approve
    flag, because there was nobody on the other end to ask. The flags are gone and this is
    what replaced them, so **the default is `allowEverything`**, which is the behaviour
    that was already there: nothing gets slower on the day this lands. `askAboutChanges`
    lets reading and searching through and stops an edit, a delete or a command;
    `askAboutEverything` stops the lot. The daemon reads it fresh on every request, so a
    change takes effect on the next question rather than the next restart. A call whose
    kind the agent did not say is treated as one that changes something, which is every
    call Grok makes. (T373.)
  - A permission request becomes an `Escalation`, and `AppModel.syncPermissions` is one
    funnel in both directions rather than a route per way of answering: the agent's page,
    the Needs you strip, a banner, the phone and the Lock Screen all land in the store,
    and this makes the store and the blocked agent agree. What makes these different from
    every other question is what an unanswered one costs: a question in a list is an agent
    carrying on with something else, and this is an agent doing nothing at all. So
    `AgentDaemon.answerWithin` is ten minutes, after which the daemon takes the
    recommendation, and the recommendation is always allow once and never allow always: a
    standing decision is not one to make for somebody because they were away from the Mac.
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
  and the `session_id` an MCP tool requires. An ACP agent is the exception and does not
  carry it: it is handed `/mcp/<its id>` and the address does that job. (T373.) The factory makes it before it launches
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
- A new tool: add it to `Tool.all` and `call`, and a test in `MCPServerTests`. A tool
  that describes an argument must read it. `task_claim`, `task_status` and `task_note`
  all take one task or several through `MCPServer.tasks(_:in:)`; two of them advertised
  `task_ids`, read only `task_id`, and refused the call without saying which half was
  wrong (T318).
- An agent is held by the daemon or by tmux, and `Agent.runtime` is the question every
  Stop, Start, Nudge and message asks before it picks a path. Add a third way of holding
  one and it is a case there, not a flag somewhere else.
- Nothing in the app asks the daemon from the main thread, for the same reason nothing
  asks tmux from it: the answer takes as long as spawning a child takes.
- Every string a person reads follows `alex-writing-voice`; no em dashes.
- Measurements come from `App/Sources/Style.swift`: `card` 18, `panel` 12, `page` 24,
  `cardPadding` 16, `sheetPadding` 20, and a chip is a capsule. They were written where
  they were used and the same thing came out at four sizes (T343). A new corner names one
  of these or it is a decision worth arguing for.
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
