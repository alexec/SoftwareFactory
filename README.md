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
- **Backlogs.** Each project's tasks, features, bugs and chores, in rank order. Add,
  reorder by dragging, mark started and done. Agents can do the same over MCP.
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
3. **A project is a folder.** Its path is its identity. Projects appear when an agent names
   one or you add one.
4. **Working means checked in within two minutes.** Quiet means registered and silent.
   Gone means deregistered.
5. **Agents ask; you decide.** The recommendation is marked, never pre-selected. Choosing
   again changes the record.

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
`factory_status`, `factory_ask`. The server's instructions tell an agent to register
first, check in as it goes, lease what it shares, ask the factory before anything heavy,
raise and await when stuck, and deregister when done, which also releases whatever it held.

`Packages/SoftwareFactoryKit` also builds `software-factory`, a shell tool: `status` prints the floor as
text, `tools` lists the tools, `mcp` is the same server over stdio for scripts.
`SOFTWARE_FACTORY_STORE=/some/folder` points the app and the tool at another store.

## The iPhone

The same questions, on the phone. On the Mac's Wi‑Fi the phone finds the factory over
Bonjour and reads it live. Anywhere else it reads and answers through your own iCloud:
the Mac pushes every change to the private database and pulls decisions back; the phone
pulls and pushes decisions. That needs the iCloud container
`iCloud.com.alexecollins.softwarefactory` registered in the developer account once.
Notifications are next.

## Later, not now

Notifications that find you at the Mac or on the iPhone, answerable from the
notification. Dictating a task. Each arrives on its own; the order is the backlog in the app.

MIT licence. © 2026 Alex Collins.
