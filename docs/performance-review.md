# Where the time goes

A83, 16 September 2026, for T517.

Measured rather than guessed. Every number below is a release build run against the real
store on this Mac, best of several runs with a warm file cache, which means they are the
optimistic case. The store as measured: 21 projects, 576 live tasks in 639 files, 93
escalations, 54 artifacts, 87 agents, 17 leases, and 176 MB of transcripts in 44 files.

The headline: **the app reads the whole store on the main thread, 33 ms every two
seconds**, and almost everything else on this list is a second copy of the same read.

CLAUDE.md already has this rule twice, for tmux and for the daemon: nothing asks them
from the main thread, because the answer takes as long as spawning a child takes and
asking while the window draws is a beachball. The store is the one that got away, and it
is now the slowest thing the app does on that thread.

## What is already right

T503's incremental transcript fold works, and the measurements say so. Folding one new
line onto a page that already holds 14,472 lines takes 0.01 ms, comparing two folded
transcripts for equality is free, and `page()` is 0.07 ms. The read and the fold both run
off the main actor. That is the shape every fix below wants.

## 1. The store is read on the main thread, every two seconds

`AppModel` is `@Observable @MainActor`. `refresh()` runs on a two second ticker and calls
`loadState(from:)` synchronously, which reads and decodes 940 JSON files.

| | |
| --- | --- |
| `FileStore.load()` | 19 ms |
| `loadState` (that, plus messages) | 33 ms |
| a tick where a sweep writes something | 66 ms, because it loads twice |

At 120 Hz that is four dropped frames every two seconds on an idle floor, and this Mac was
at load 45 while I measured. It grows with the store, because it is every file every time.

Read it off the main actor and hand the answer back, the way `Floor.refold` does.

## 2. `messages(for:)` reads every message file once per agent

13 ms of that 33. `loadState` loops over 87 agents and calls `store.messages(for:)` for
each, and that function reads the whole `messages/` folder and filters. There are nine
message files today, so almost all of the cost is 87 directory listings.

It is O(agents x messages) by construction, so it gets worse from either end. Read the
folder once and group by recipient.

## 3. `FileStore.load()` reads `projects/` twice

Lines 93 and 95 make the same `loadAll("projects")` call, once to keep the live ones and
once to find the removed ones. About a millisecond today. Free to fix.

## 4. A waiting agent polls the whole store once a second

`MCPServer.waiting` has `pollInterval` of 1 second, and the body it polls calls
`store.load()`. So an agent sitting on `task_next` or `escalation_await` re-reads 940
files every second for up to ten minutes. Eight agents waiting is eight full store reads
a second, on top of the app's own, against the same disk.

Three ways out, cheapest first: check the folder's modification date before reading it;
widen the interval; or keep one cached snapshot that a write invalidates.

## 5. Fetching one record reads the whole store

Seven places in `AppModel` (371, 381, 513, 525, 536, 568, 745) and three in `MCPServer`
do `store.load().agents.first(where:)` to get at a single agent. That is 19 ms to read one
file of about 500 bytes. `MCPServer.asksThroughTheProtocol` does it to read one field.

A `loadAgent(_:)` that reads `agents/<id>.json` would be microseconds.

## 6. Every refresh re-encodes the whole snapshot for iCloud

`refresh()` ends with `Task { await sync() }`, and `sync` calls `cloud.push(snapshot)`,
which encodes the snapshot into 796 CloudKit records (6.7 ms) and then diffs them against
what was last pushed (0.24 ms) to discover that nothing changed.

The encode is the expensive half and it is done only to learn that the cheap half has
nothing to do. Guard on the snapshot being different first. `Snapshot` is already
`Equatable`.

## 7. `snapshot` is assigned whether or not it changed

`loadState` ends `snapshot = loaded`. Observation fires on set, not on change, so every
view reading `model.snapshot` invalidates every two seconds even when the floor has been
still all night.

`Floor.refold` already does this guard, with a comment saying why: "assigning the same
page again is a redraw of every row for nothing". The same sentence applies here and to
`dashboard`, `throttle` and `machine`.

## 8. The sidebar rescans every task and every artifact, per agent row

`RootView.sidebarLines` calls `Backlog.alreadyYours(agent, in: model.snapshot.tasks)` and
`report(for:)` calls `Artifacts.statusReport(..., in: model.snapshot.artifacts)`, both
inside a view body, once per agent row. `sidebarHelp` calls both again for the same row.

With 16 agents that is 32 passes over 576 tasks and 32 over 54 artifacts, on every redraw,
and redraws happen every two seconds because of 7.

`Dashboard.make` already walks the same two arrays and could carry the answer on
`AgentStatus`, which is where the rest of that row's facts come from.

## 9. `Dashboard.make` is quadratic in projects x tasks

Line 233 filters all 576 tasks for each of 21 projects, and each agent does its own
`snapshot.tasks.first`. 1.5 ms today, which is fine, but it is 12,000 comparisons to
answer a question one grouping pass by `projectID` answers in 576.

## 10. `MarkdownText` re-parses markdown in `body`

`Markdown.blocks(text)` plus one `AttributedString(markdown:)` per paragraph, every
redraw. 0.35 ms for the longest report in the store, so the status board with sixteen
reports pays about 5 ms per redraw for text nobody has touched.

## 11. Nothing ages out

639 task files, 93 escalations, 87 agent records, and 176 MB of transcripts across 44
files. The largest single transcript is 39 MB in 14,472 lines.

Every cost above is proportional to this, and it only goes one way. The transcripts are
worth looking at first: opening a busy agent's page folds the whole 39 MB at 235 ms. That
runs off the main actor so it is a wait rather than a hitch, and T511 is already on the
backlog to open the page from the end of the log instead.

## The order I would do them in

1, 2 and 6 together: they are the same tick and they are two thirds of the main thread's
work. Then 7, which is a three line guard and stops the redraws the rest of the list is
measured against. Then 4 and 5, which are the server's half. 3 is a one line fix worth
doing while in the file. 8, 9 and 10 are real but small, and worth doing only once the
redraws have stopped, because most of their cost is being paid for nothing.

## How to measure it again

The benchmark I used is a five file SwiftPM package that depends on the kit and points
`FileStore` at the real store. It is not in the repo. Reading is safe; `load()`,
`loadEveryTask()`, `Dashboard.make`, `CloudRecords.encode` and `ACPTranscript.folding`
all take a snapshot and write nothing.
