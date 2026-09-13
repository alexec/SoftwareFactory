# Software Factory

A Mac app that is the floor of a software factory:
coding agents do the work, and you make the calls.

The factory is this Mac. Agents of any kind register with it over MCP, pick up tasks
from a project's backlog, check in with what they are on, and ask when they cannot decide
something themselves. You see all of it in one window and answer the questions with a click.

## This version, the narrowest slice

- **Needs you.** An agent raises a question with two or more options and marks the one it
  recommends. It sits at the top of the floor until you click an option. The agent, which
  has been waiting on `escalation_await`, gets the answer and carries on.
- **On the floor.** Every registered agent, which project it is in, what it is on, and
  when it last checked in.
- **Backlogs.** Each project's tasks, features, bugs and chores, in rank order. Add at the
  top or the bottom, reorder by dragging, park what you are not going to do and unpark it
  later. Agents file tasks anywhere on the list, pick them up, and are the only ones who
  say a task is in progress or done: that is their work to report, not yours to mark.
- **Resources.** Things only so many agents can use at once: a phone, a simulator, the
  browser, the whole Mac. Each has slots and a longest lease. An agent leases a slot,
  saying why and for how long, and gives it back; a lease that runs out is over on its
  own. You can take one back.
- **The factory.** This Mac: memory, swap, load, compiles and simulators running, and a
  verdict (under capacity, tight, over). An agent asks before starting anything heavy and
  is told yes, wait or no, with the reason. The throttle (compiles at once, simulators at
  once, the swap ceiling, the memory floor) is set only in the app.

## The rules

1. **The app knows nothing about what an agent runs on.** Claude Code, another CLI, a
   script: if it speaks MCP it is an agent. Nothing here reads another tool's files.
2. **One store, many writers.** Every project, task, agent and question is one JSON file in
   `~/Library/Group Containers/6T4RVD5724.com.alexecollins.softwarefactory/Store`. The app and
   the server both read and write it; writes are atomic and one file per record, so a
   half-written file is never read.
3. **A project is a name.** An app, a role that spans apps such as research, a piece of
   tooling: it needs no folder. Projects appear when an agent names one or you add one.
   An agent that still sends a folder path gets the folder's name.
4. **Working means the agent touched the factory in the last ten minutes.** Quiet means
   registered and silent; an hour of silence and it is marked gone. There is no check-in
   to forget: a claim, an update, a question or a lease is the heartbeat.
5. **Agents ask; you decide.** The recommendation is marked, never pre-selected. Choosing
   again changes the record.
6. **A task's progress is the agent's word.** You add, rank, park and delete. An agent
   claims, and says done. (Alex, 12 September 2026.)
7. **A blocked task says what it waits on, and nobody waits with it.** An agent marks the
   block (a decision, another task, a person) and picks up the next task. The factory
   unblocks it when the decision lands or the task is done; a block on a person clears
   when they say so.

## Connecting an agent

The MCP server runs inside the app, on port 4747, while the app is open. Register it with
Claude Code once (Settings has the command with a Copy button):

```bash
claude mcp add --transport http --scope user software-factory http://127.0.0.1:4747/mcp
```

The tools: `agent_register`, `agent_checkin`, `agent_deregister`, `project_list`,
`project_add`, `task_list`, `task_next`, `task_add`, `task_claim`, `task_status`,
`task_rank`, `task_remove`, `escalation_raise`, `escalation_await`, `escalation_list`,
`resource_list`, `resource_add`, `resource_lease`, `resource_renew`, `resource_release`,
`factory_status`, `factory_ask`, `task_block`, `task_unblock`, `task_move`, `task_show`, `task_note`, `task_number`, `project_remove`. Task kinds: feature, bug, chore, review, ship.
There is no check-in: every call an agent makes counts as a sign of life. The server's
instructions tell an agent to register first, work from the backlog and never a parked
task, claim what it is on, lease what it shares, ask the factory before anything heavy,
raise and await when stuck, stop when a project is on hold, and deregister when done,
which also releases whatever it held.

`Packages/SoftwareFactoryKit` also builds `software-factory`, a shell tool: `status` prints the floor as
text, `tools` lists the tools, `mcp` is the same server over stdio for scripts.
`SOFTWARE_FACTORY_STORE=/some/folder` points the app and the tool at another store.

## The iPhone

The same questions, on the phone. On the Mac's Wi‑Fi the phone finds the factory over
Bonjour and reads it live. Anywhere else it reads and answers through your own iCloud:
the Mac pushes every change to the private database and pulls decisions back; the phone
pulls and pushes decisions. That needs the iCloud container
`iCloud.com.alexecollins.softwarefactory` registered in the developer account once.

**Away from the Mac.** The phone asks once, from a primer, whether it may notify you.
Then iCloud sends the phone a silent push whenever the Mac writes a question, a task or
a project; the app wakes, reads the store, refreshes the lists and the Lock Screen, and
posts a banner for each new question with its options as the actions. Answer from the
banner and the decision goes back through iCloud; the Mac adopts it within fifteen
seconds and the agent waiting on it moves on.

**On the Lock Screen.** While a question is open it sits on the Lock Screen and in the
Dynamic Island as a Live Activity, with its options as buttons: answer without unlocking.
It shows the newest question and how many more wait. Without a push server it is kept
current only while the app is open, so it is marked stale after fifteen minutes.
Notifications are next.

- **A note with the answer, or your own answer.** Under the options there is one field.
  Typed before clicking an option it rides along as a note; sent on its own with "Answer
  with this" it is the answer, none of the options. The agent gets it from
  `escalation_await` either way. On the phone too.
- **Open and Nudge.** Each agent on the floor says what it runs on and links to its own
  session, so you can open it and look under the hood. Nudge sends the word "nudge" to
  the agent with its next reply from the factory.
- **A new task reaches an idle agent on its own.** For Claude Code, whose session id the
  factory already has from registration: when its session is about to go idle, its own
  Stop hook asks the factory whether there is anything waiting; the first time there is,
  the factory tells it instead of letting it stop, once per task. Needs the hook added to
  `~/.claude/settings.json`, pointed at `http://127.0.0.1:4747/api/stop_hook`.
- **A word for the agent.** On a project's page, Mac or phone, type a note and send it. It
  waits on the project, and can be taken back, until an agent's next call about that
  project; then it goes out once at the end of that reply, "NOTE FROM ALEX: …", and is
  gone. Away from the Mac the note goes through iCloud and the Mac picks it up.
- **Answered questions fold away.** A decided question becomes one line in the project
  view, and only the newest three stay; the store keeps them all.
- **A banner at the Mac.** Each new question is a macOS notification with the options as
  its actions. Asked for once, in place, before the system alert.
- **Adding a task.** Type it into the add row; the first line becomes the title,
  anything after it is the note. Dictating one is out for the moment (`DictateField`
  is still in `Shared/`, not called from either add row); it did not work well and
  will come back once that is fixed.

MIT licence. © 2026 Alex Collins.
