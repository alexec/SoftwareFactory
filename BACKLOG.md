# Backlog

What's planned, and what will never be built. The first version is the narrowest slice:
agents register and ask over MCP, the floor shows it, a click answers. Everything below
arrives on its own, roughly in this order.

1. **Resources.** Each with a number of slots and a longest lease. `resource_list`,
   `resource_lease` (time-bound; returns a lease or a queue position), `resource_renew`,
   `resource_release`. An expired lease is taken back. A Resources tab.
2. **The factory's capacity.** Memory, swap, CPU, compiles running. `factory_status`,
   `factory_ask` ("can I start a compiler?": yes, wait, or no, and why), the throttle
   (compile slots, simulators at once, the swap ceiling), set only in the app. A Factory
   tab.
3. **Notifications at the Mac.** A macOS notification per question, the options as its
   actions, primed first. Presence is "screen unlocked and input in the last two minutes".
4. **iPhone.** The store synced through the person's iCloud (CloudKit, private database).
   CloudKit pushes a question to the phone when the Mac decides you are not at it, or 90 s
   after an unanswered Mac notification; the options are the notification's actions. The
   first version is the questions list and its notifications.
5. **Dictate a task.** A mic on the add field; words appear as they are recognised
   (`SFSpeechRecognizer` for feel, `SpeechTranscriber` for the words, the house way).
6. **Gone agents.** Three missed check-ins and an agent is marked gone without
   deregistering; its leases expire.
7. **Agent log.** `agent_checkin` notes kept as a log per agent and per task, shown on the
   project view.
8. **Decided questions age out.** The project view shows the last few; the rest are kept.
9. **Icon.** `Tools/make-icon.swift` drawing it with Core Graphics, a full macOS icon set.
10. **Store schema version.** A `version` field on every record and a reader that copes
    with older shapes, before the iPhone makes two writers of different ages.
11. **Register the server from the app.** A button that writes the Claude Code entry
    itself, if a supported way appears; today it is a command to copy.
12. **Raise a bug or a feature from the floor.** A field that files against the right
    project. Alex asked for this to wait.

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

## Minor review findings

_None yet; no review has run._
