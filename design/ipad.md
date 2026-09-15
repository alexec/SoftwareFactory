# The iPad app, as a proof of concept

T202. A37, 14 September 2026. The plan for T189.

## What it is

The floor on a big screen you can pick up. Everything the Mac app shows, shown on an
iPad: the dashboard, the agents, capacity, every project's backlog, the questions waiting
on you, the documents agents file. Everything the Mac app does, done from the iPad, with
two exceptions that no plan can talk its way out of: an iPad cannot start a process, and
it cannot show a terminal.

It does not need to. The Mac app already reads the store every 2 seconds and acts on what
it finds there. `wantsLaunch` makes it start an agent in a terminal it owns. A message
written down for an agent makes it type that message into one. The iPad writes a record and the Mac does the work. Remote
control is not a new channel to build; it is the channel that is already there, with more
verbs on it.

## What it cannot do, and says so

- **No terminal.** SwiftTerm and tmux are the Mac's. The agent page on iPad shows what the
  card shows: the name, the title line the agent last set, whether it is working, its
  tasks, the messages it has been sent, and Nudge. Where the Mac has the terminal, the iPad
  says the terminal is on the Mac. It does not fake a read-only one for the proof of
  concept. If reading the last lines turns out to matter, `tmux capture-pane -p` is text
  and the Mac could put it in the snapshot. That is its own task, later.
- **No agent started here.** Start an agent still means the Mac starts it. The iPad picks
  the project, the task and which CLI, and the Mac opens the terminal.
- **Nothing at all when the Mac is off.** Reading, deciding and adding a task go through
  iCloud when the factory is out of reach, exactly as the phone does now. The buttons
  that need the Mac are hidden while it is out of reach rather than queued. A button that
  will happen later is worse than a button that is not there.

## One app, not two

Grow the iPhone target into a universal app: `TARGETED_DEVICE_FAMILY` "1,2". Same bundle
id, same App Store record, same iCloud container, same widget extension, one copy of
`PhoneModel`, `FactoryClient`, `CloudSync` and the notifier. A second target would be a
second copy of all of it and a second listing to keep in step.

What the target file needs:

- `TARGETED_DEVICE_FAMILY: "1,2"` on the app and on the widgets extension.
- Landscape on iPad. `UISupportedInterfaceOrientations` stays portrait for iPhone;
  `UISupportedInterfaceOrientations~ipad` gets all four.
- `NSMicrophoneUsageDescription` says "this phone" today. Reword it; the same app runs on
  an iPad now.
- Live Activities work on iPadOS. The Lock Screen view is the same; the Dynamic Island
  simply never appears. Nothing to write, only to check.

Layout follows the width, not the device. Regular width gets the Mac's shape: a
`NavigationSplitView` whose sidebar is Dashboard, Agents, Capacity, No project, then the
projects, which is `RootView`'s list. Compact width gets today's `PhoneRootView`, which is
what an iPhone shows and what an iPad shows in Slide Over.

The iPad pages are written in `Phone/Sources` against `PhoneModel`, with the Mac's views
as the reference for layout. The Mac app is not refactored for this. The cost is real:
two views drawing the same dashboard. Pay it for the proof of concept, and when it is
proved, pull them into `Shared` behind one protocol both models satisfy, the way
`ArtifactCard` and `WorkField` already are. That tidy-up is a task, not a
precondition.

## The channel: one command, not fourteen routes

Today the factory answers `GET /api/snapshot`, `POST /api/decide`, `/api/task`,
`/api/task/edit`, `/api/task/set`, `/api/task/place` and `/api/task/move`. To match the
Mac the iPad also needs to: start an agent on a project or on one task, nudge one, send it
a message, delete one, add a project, remove one, put one on hold, set its folder, add a
resource, remove one, take a lease back, answer a question in words rather than by
picking, take a task back from an agent, delete one, unblock one, and remove an artifact.

Do not add sixteen routes. Put a `FactoryCommand` in the kit: a Codable enum, one case per
verb, with `apply(_:to:)` that takes the store and does it. Test it in the package, where
the rules go. Add one route, `POST /api/command`. The phone and the iPad share the
encoder, there is one place to add a verb, and one place where it is proved. The existing
task routes stay until nothing calls them.

Commands that the app must act on rather than the store are already flags:
`launchAgent(project:task:which:)` reserves the agent and sets `wantsLaunch` with the
`LaunchAgent` the person picked, and the Mac opens the terminal on its next read. A Mac
running an older build answers 400 to a verb it does not know, and the iPad says so
plainly instead of failing silently.

## The work, in order

Each one ends with something you can hold.

1. **Universal target.** Family, orientations, the strings. Run today's phone screens on
   an iPad and fix what breaks at that width. No new UI, and the phone is unchanged.
2. **`FactoryCommand` and `/api/command`.** Kit types, `apply`, tests, the route. No UI.
   Drive it with curl and watch the Mac react.
3. **The floor, read only.** The split view: dashboard, agents, capacity, projects,
   backlogs, artifacts, questions. All of it straight from the snapshot the iPad already
   polls.
4. **The buttons that write.** Decide a question, add and rank tasks, start an agent with
   the launch chooser, Nudge, hold a project, add and remove projects and
   resources, take a lease back.
5. **The agent page without a terminal.** Title line, activity, bell, tasks, the messages
   it has been sent, the buttons, and one honest line about where the terminal is.
6. **First run on iPad.** The intro sheet in the same three parts, How it works at the top
   of Settings, and every word that says phone checked.

## What it proves

That one app is the floor on any screen, and the Mac is the only machine that runs
anything. If that holds, the iPad is not a companion app. It is the same app, sitting
further from the compiler.

## Decisions for Alex

- **One universal app rather than a separate iPad app.** Recommended, for the reasons
  above. It changes the iPhone app's App Store record from iPhone to iPhone and iPad.
- **The iPad may start agents.** Recommended. The Mac still does the starting, so nothing
  new can go wrong, and starting work from the sofa is most of the point.
- **No terminal text on iPad in the proof of concept.** Recommended. Add it later if
  reading a pane turns out to be what you reach for.
