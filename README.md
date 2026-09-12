# Software Factory

Working title; code name Foreman. A Mac app that is the floor of a software factory:
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

## The rules

1. **The app knows nothing about what an agent runs on.** Claude Code, another CLI, a
   script: if it speaks MCP it is an agent. Nothing here reads another tool's files.
2. **One store, many writers.** Every project, task, agent and question is one JSON file in
   `~/Library/Group Containers/6T4RVD5724.com.alexecollins.foreman/Store`. The app and
   the server both read and write it; writes are atomic and one file per record, so a
   half-written file is never read.
3. **A project is a folder.** Its path is its identity. Projects appear when an agent names
   one or you add one.
4. **Working means checked in within two minutes.** Quiet means registered and silent.
   Gone means deregistered.
5. **Agents ask; you decide.** The recommendation is marked, never pre-selected. Choosing
   again changes the record.

## Connecting an agent

The MCP server is the `foreman-mcp` executable inside the app (the same program as `foreman`, named so it cannot collide with the app binary on a case-insensitive disk). Settings shows the command,
which is:

```bash
claude mcp add --scope user foreman -- "/Applications/Software Factory.app/Contents/MacOS/foreman-mcp" mcp
```

The tools: `agent_register`, `agent_checkin`, `agent_deregister`, `project_list`,
`project_add`, `task_list`, `task_next`, `task_add`, `task_claim`, `task_status`,
`task_rank`, `task_remove`, `escalation_raise`, `escalation_await`, `escalation_list`.
The server's instructions tell an agent to register first, check in as it goes, raise
and await when stuck, and deregister when done.

`foreman status` prints the floor as text; `foreman tools` lists the tools;
`FOREMAN_STORE=/some/folder` points both the app and the server at another store.

## Later, not now

Resources with slots and time-bound leases. The factory's own capacity: memory, CPU,
compile slots, a verdict agents ask before starting anything heavy, and a throttle.
Notifications that find you at the Mac or on the iPhone, answerable from the notification.
The iPhone app. Dictating a task. Each arrives on its own.

MIT licence. © 2026 Alex Collins.
