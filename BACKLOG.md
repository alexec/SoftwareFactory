# Backlog

**The backlog lives in the factory itself** since 12 September 2026: open the Mac app and
click Taktu: Software Factory in the sidebar, or ask the server with `task_list`. Agents file,
claim, rank and finish tasks there; so does this file's former list. What stays here is
the thinking that does not fit a task row.

## Won't build

- **Reading another tool's files.** The app knew how to read Claude Code's sessions once
  and that was removed on 12 September 2026: the factory is ignorant of what an agent
  runs on. Agents say what they are doing; the app never guesses.
- **A lock the app takes itself.** The app is a window; it never holds a resource an agent
  wants.
- **Making the choice for the person.** The recommendation is marked, never pre-selected
  and never auto-applied after a timeout.
- **A dot in a tool name.** MCP clients disagree on what a name may contain; underscores
  work everywhere.
- **The server as a separate process.** It ran as an embedded executable for an hour on
  12 September and moved into the app on a port the same day: one address every client
  shares, and the factory is open exactly while the app is.
- ~~**A kind on a task.**~~ Feature, bug or chore came out on 12 September because nothing
  read it. T166, 13 September 2026, put **work** on a task instead: design, plan,
  implement, fix, review, investigate or ship. The agent reads it; it is what to produce,
  not a taxonomy.

## Decisions worth keeping

- **The phone talks to the factory over the local network first**, through Bonjour and
  the same port, speaking the package's own HTTP over a Network connection rather than a
  URL (a link-local IPv6 address with a scope defeats URLSession). CloudKit is the way
  off the Wi‑Fi and is on the backlog in Alex's words.
- **`Task` is called `FactoryTask` in Swift** because `Task` is Swift's. It is a task
  everywhere a person reads it.

## Minor review findings

_None yet; no review has run._
