# Foreman

A Mac app that shows what your coding agents are doing and what they need from you.
Working title; the name is not settled.

Several Claude Code sessions run at once, each in its own project. Foreman is the one
window across all of them:

- **How much is in flight.** How many tasks are in progress, how many questions are
  waiting for you, how many projects have an agent on them right now.
- **Each project's state.** Working, waiting or idle, and what it is on: the backlog item
  an agent has picked up, or failing that the last thing the agent was asked.
- **Escalations.** When an agent cannot decide something itself it raises a question with
  two or more options and marks the one it recommends. You pick one. The choice is
  recorded against the escalation, where the agent reads it back.
- **Backlogs.** Every project has a prioritised list of features, bugs and chores. Add to
  it, reorder it, mark things started and done.

## The rules

1. **One store, many writers.** Every project, task and escalation is one JSON file in a
   folder that the Mac app, the command line, and later the iPhone app and the agents' MCP
   server all read and write. The folder is the app group container,
   `~/Library/Group Containers/6T4RVD5724.com.alexecollins.foreman/Store`. Writes are
   atomic, one file per record, so writers rarely collide and a half-written file is
   never read.
2. **Claude Code is read, never written.** The app finds sessions from Claude Code's own
   files under `~/.claude`: the registry of running sessions and the transcripts. You
   point it at that folder once. Nothing is sent anywhere.
3. **A project is a folder.** Its path is its identity, in the store and in Claude Code.
   Projects appear on their own when a live session is in them; they are written to the
   store the first time something is filed against them, or when you add one.
4. **Working means the transcript moved in the last ninety seconds.** Waiting means the
   session is alive and quiet. Idle means nobody is on it.
5. **An escalation is an agent's question with options.** At least two, one recommended.
   Choosing records the option and the time; choosing again changes the record.

## The command line

`Packages/ForemanKit` builds a `foreman` executable that reads and writes the same store,
so an agent can file work and raise questions today, before there is an MCP server:

```bash
cd Packages/ForemanKit && swift build -c release --product foreman
.build/release/foreman status
.build/release/foreman task add ~/Where "Rooms run together when dictated" --kind bug
.build/release/foreman escalate ~/Packed "Which weather source?" \
    --option "WeatherKit|Apple's own, needs the capability" \
    --option "Open-Meteo|Free, no key" --recommend 1 --by "Packed lead"
.build/release/foreman decide <id-prefix> 1
```

`FOREMAN_STORE=/some/folder` points both the app and the command line at another store.

## Later, not now

Locks on shared resources (a device, a browser) that agents take through MCP. An MCP
server over the same store. An iPhone app that syncs the store so questions can be
answered away from the Mac. Apple Intelligence for summaries and transcription for
answering by voice. Each arrives on its own; none is in this version.

MIT licence. © 2026 Alex Collins.
