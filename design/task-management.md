# How a task is managed

Asked for in T264, after tasks that were edited or deleted came back on the display
with nothing said. (Alex, 15 Sep 2026.)

## Where a task lives

One JSON file under `tasks/` in the store. Nothing else holds a copy that counts. The
app reads every file into `snapshot` every two seconds; the MCP server reads and writes
the same files from its own connections; the phone reads through `/api/snapshot` when
it can see the Mac and through CloudKit when it cannot.

## What may change it

- **The person, in the app.** Add, edit, park, rank by dragging, delete, take back off
  an agent, unblock. Each goes through `AppModel.persist`, which writes the file and
  then reloads the store.
- **An agent, over MCP.** `task_add`, `task_claim`, `task_status`, `task_note`,
  `task_block`, `task_unblock`, `task_set`, `task_remove`, `task_number`.
- **The person, on the phone.** Straight to the Mac over HTTP when it is on the network,
  and to CloudKit when it is not.
- **The factory itself.** `Sweep.unblocked` puts a task whose blocker has cleared back on
  the backlog; `Sweep.stoppedAgents` gives back what a dead agent held.

The rules all live in `Backlog` in the package, as pure functions, so no view decides
anything: `Backlog.set`, `edit`, `remove`, `assign`, `place`, `unblock`, `personMaySet`.

## Nothing is deleted

Delete sets `removed` and adds a line saying who and why. `FileStore.load()` drops
removed tasks, so they leave every list while the file stays on disk. `loadEveryTask()`
sees them, which is how a task number is never handed out twice.

## What was wrong

**The cloud put deleted tasks back.** `tasksToAdopt` was given `snapshot.tasks`, which
has no removed tasks in it. So a task the person deleted here was, to that comparison, a
task that existed on another device and not on this one: it was adopted and written
straight back to disk. Any pull within fifteen seconds of a delete could do it, and a
stale CloudKit record left by a delete that happened while the app was closed did it on
every launch, for ever. `taskChangesToAdopt` could undo a removal the same way, by
copying a `removed` of nil off an older cloud record onto a task the person had just
deleted.

Fixed: both are measured against every task on disk, removed ones included, a cloud copy
that is itself removed is not adopted, and a removal is never undone by a pull.

**A failed write said nothing.** `persist` caught the error into `storeError` and then
called `refresh()`, whose first act on a good read is `storeError = nil`. The message
lasted one line. Settings, the only page that showed it, showed it only when there was
no store at all, so that branch could not be reached. The row then redrew from disk
exactly as it had been. An edit that did not happen and an edit that changed nothing
looked identical.

Fixed: a write failure is its own thing, `AppModel.writeError`, which a refresh does not
clear, and it is said on a banner across the top of the window until the person says OK.
The agent launcher and the Agents page were reading `storeError` for the same purpose and
had the same problem; they read `writeError` now.

## What is still true and worth knowing

- The two-second refresh means a change the person makes is visible within two seconds,
  and so is one an agent makes. There is no push.
- `CloudSync.lastPushed` is in memory, so the first push after a launch sends everything
  and deletes nothing. A record deleted while the app was closed is not deleted from
  CloudKit on the next run. That no longer resurrects anything, because the adoption
  check reads every task on disk, but the stale record does sit there.
- Numbers come from `Backlog.nextNumber` over every task ever, so they are not reused.
