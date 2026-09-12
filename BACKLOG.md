# Backlog

What's planned, and what will never be built. The first version is the dashboard, the
shared store and the Claude Code scan; everything below arrives on its own.

1. **Resource locks.** Define resources (his iPhone, the iPad, the Mac, Chrome) and let
   agents take and release locks on them. The store grows a `locks/` folder; the
   dashboard shows who holds what.
2. **MCP server.** The same calls the `foreman` CLI makes, offered as tools: file a task,
   start it, finish it, raise an escalation, read the decision, take a lock.
3. **iPhone app.** The store synced through CloudKit so escalations can be answered away
   from the Mac. Read-mostly: answer questions, read the dashboard, add to a backlog.
4. **Apple Intelligence.** A one-line summary of what each agent has been doing, from the
   transcript tail, on device.
5. **Transcription.** Answer an escalation, or add a task, by voice. Words appear as they
   are recognised, the house way.
6. **Raise a bug or a feature from the app.** A field on the dashboard that files against
   the right project. Alex asked for this to wait.
7. **Read `~/Tracking` boards.** The existing markdown boards hold real work; an importer
   or a reader would put them on the dashboard without re-filing.
8. **Agent-side task pickup.** When an agent starts, mark the task it was briefed with as
   in progress from the session itself (a hook that calls `foreman task start`).
9. **Icon.** `Tools/make-icon.swift` drawing the icon with Core Graphics, a full macOS
   icon set.
10. **Notify when a question arrives.** A local notification, primed first, off by default.
11. **Decided escalations age out of the project view.** Show the last few; keep the rest.
12. **Store schema version.** A `version` field on every record and a reader that copes
    with older shapes, before the iPhone app makes two writers of different ages.

## Won't build

- **A "lock" the app takes itself.** The app is a window; it never holds a resource an agent
  wants.
- **Making the choice for the person.** The recommendation is marked, never pre-selected
  and never auto-applied after a timeout.
- **Writing to Claude Code's files.** Read only, always.

## Minor review findings

_None yet; no review has run._
