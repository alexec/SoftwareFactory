# What should age out of the store

T527, 17 September 2026. Measured on this Mac's store, not estimated.

Alex answered the question behind this one (escalation 80C58D5D) with **archive rather
than delete**: old records move to a folder the app does not read, the store keeps only
the live ones, nothing is lost, and a question about last July is answered by going to
look. This brief is what that means in practice, and it changes one thing about how I
would have written the rule.

## The store today

| | records | | |
|---|---|---|---|
| tasks | 673 | 512 finished, 42 removed | 107 live |
| escalations | 110 | 110 decided | 0 open |
| agents | 91 | 76 deregistered, 9 archived | 6 on the floor |
| projects | 36 | 16 removed | 20 live |
| leases | 33 | 16 expired | 17 live |
| artifacts | 65 | | 21 live |

`load()` reads 943 records. 166 of them are live. The other 82% are history.

Transcripts are 288 MB across 52 files, in a folder of their own that `load()` never
touches.

## The first finding: nothing is old

The oldest record in the store was made on 12 September. The whole thing is 4.4 days old.

A rule that archives a record after thirty days would archive nothing today, and nothing
for another twenty-six days. By then, at the rate this factory is going, there would be
about 6,300 records and two gigabytes of log to move in one go.

**Age is the wrong axis on its own.** What makes a record dead here is not how long ago
it was written, it is that it is finished: a task that succeeded, a question that was
decided, an agent whose process has gone. Those happen in hours, not months.

Per day, measured over the 4.4 days: 155 tasks, 25 questions, 21 agents, 8 projects, and
65 MB of transcript.

## The proposal

### A. Archive by state, with a day's grace

An `archive/` folder beside `projects/`, `tasks/` and the rest, same one-file-per-record
layout, which `load()` never reads. A record moves there when it has been finished for
more than a day:

- a task succeeded, failed or removed
- a question decided
- an agent deregistered or archived, with its messages and leases
- a project removed, with its tasks and artifacts
- a lease past its time

**A day rather than thirty**, because the app shows the newest three finished tasks on a
project and the newest three decided questions, and one day is comfortably more than
three of either at this rate. The grace exists so that a task marked done and then
reopened a minute later never went anywhere.

There is already a precedent for reading past the live set: a removed project keeps its
record and drops out of `load()`, and `loadRemovedTasks()` and `loadEveryTask()` are how
the two callers that need the history ask for it. Show more on a project's done tasks
becomes the third such caller, and the archive is the same idea one step further on.

Measured by building a store of only the live records and reading it:

| | today | live only |
|---|---|---|
| `load()` | 22.41 ms | 3.53 ms |
| `stamp()` | 2.28 ms | 0.50 ms |

Six times faster, and it stays that way instead of getting worse every day. `load()` runs
every two seconds in the app and `stamp()` once a second per waiting agent.

### B. A deleted agent's transcript goes with the agent

49 MB of the 288 belongs to agents whose records are not in the store at all. Deleting an
agent removes its record (`FileStore.delete(_ agent:)`) and clears the fold held in
memory (`Floor.forget`); nothing has ever taken the log off the disk. There is no agent,
no page, and no way to read it.

This is a leak rather than a policy question, and the fix is three lines. It moves to the
archive like everything else rather than being deleted, which is what Alex chose, and
which here costs nothing: it is 49 MB either way and the app never reads it either way.

### C. Roll a live agent's transcript

The largest single file is 73.5 MB and it belongs to an agent that is **still working**.
The top five files are 64% of all the bytes. Neither A nor B touches this, and it is the
half that grows.

Once a live log passes a threshold, the head of it moves to
`archive/transcripts/<agent>.<n>.jsonl`, cut at a turn boundary, which is the only safe
place to cut one. Scrolling back already reads a transcript backwards a fold at a time
(`FileStore.transcriptBefore`, T542), so it can follow into the rolled files with no
change to how the page works.

Eight megabytes is the number I would start with: it is well past what a page ever folds
at once, and it would leave the busiest agent's live log at a tenth of what it is.

## What I would not do

Do not throw away decided questions. They are the record of what Alex decided and why,
they are 460 KB in total, and they are the one kind of record here whose whole purpose is
to be looked at later.

Do not make this a setting. Every value of it is wrong for somebody and the person should
not have to have an opinion about a folder they never see.

## Order

B first: it is a leak, it is three lines, and it is 49 MB.
A second: it is the one that makes every read in the app smaller and keeps it that way.
C last: it is the largest saving and the most work, and T542's scroll-back has to be seen
working by hand before something else starts relying on it.
