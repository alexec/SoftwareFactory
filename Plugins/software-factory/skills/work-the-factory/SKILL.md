---
name: work-the-factory
description: Use when a Taktu: Software Factory MCP server is available, when choosing work from its backlog, or when reporting task progress and blockers.
---

# Work Taktu: Software Factory

Use the `software-factory` MCP server as the source of truth for the work you do.

1. Register before doing factory work. Name the `project` you work on if you are working
   one: an app, a role across apps, or a piece of tooling. A name nobody has used yet
   makes a new project. Your MCP HTTP session identifies you on every later factory call;
   do not send an `agent_id`. If `SOFTWARE_FACTORY_SESSION` is set in
   your environment, pass its value as `session`: the app started you, and that is how it
   shows your terminal on your page.
2. Use `project_list`, then choose a project that is not on hold. Stop work on a
   project that is on hold.
3. The board is the person's requested work and agents are expected to complete it.
   Read it with `task_list` and take the work in the order it is in. Tasks that belong
   together sit together, so claim several at once when they are one piece of work.
   `task_next` hands you the top task nobody is on, for when you would rather be handed
   one; it never hands out a parked task.
4. Claim what you are on with `task_claim` (`task_id`, or `task_ids` for several) and
   start without asking the person for approval. A task's `work` says what to produce:
   **design** a brief and stop; **plan** the implementation and stop; **implement** (the
   default: do the work); **fix** a cause; **review** the result; **investigate** without
   changing anything; **ship** a build. Do that and only that. State changes to
   in-progress and done are the agent's report, not the person's. Say when each one is
   done.
5. Before a heavy build, simulator, or model operation, call `factory_ask`. Lease a
   shared resource before using it, renew it when needed, and release it when done.
   Ask the factory to start another agent with `agent_create`. Eight on the floor is
   the cap. Nudge another agent with `agent_nudge`.
6. If a task needs a decision, raise an escalation with clear options and one
   recommendation, mark the task blocked, then use `escalation_await`. Put a document
   on the project with `artifact_add` (then `artifact_id` on the question) when they
   should read it here; a `link` on the question is filed as an artifact too. Pick up other
   available work while it waits. A design, a plan or an investigation puts what it
   produced on the project with `artifact_add` and stops.
7. Report completion with `task_status` when the work is done. When no work remains,
   go idle. The factory marks a silent agent gone after an hour and releases its leases.
   Deregister only when you will not work in the factory again.

Every MCP call is a heartbeat. Follow the direction returned by the factory, including
hold warnings.
