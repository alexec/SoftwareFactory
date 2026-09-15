# Rebuilding the floor on ACP

A plan. Follows `acp.md` (T367), which said wait. This says what it would take if we
do not wait.

## The one problem, and the only honest answer

An ACP agent is a subprocess of its client. Make the app the client and every rebuild
kills the floor, a dozen times a day. That is not a cost to accept, it is the feature
being removed.

So the plan is a daemon: `software-factory agentd`, which owns every ACP subprocess and
outlives the app. The brief called that "tmux's job rewritten by us, badly", and it is
right about whose job it is and wrong about the size. We are not rewriting tmux. tmux is
a terminal multiplexer: pty allocation, ANSI parsing, scrollback, resize, copy mode,
window layout. None of that exists under ACP. The agent's side of the pipe is
line-delimited JSON. What the daemon does is hold a pipe open, append what comes out of
it to a file, and let one or more clients attach. That is a few hundred lines, and every
one of them is code we can read.

If that is not worth owning, the answer stays wait. Everything below assumes it is.

## The shape afterwards

```
app  <--unix socket, ndjson-->  agentd  <--stdio, ACP-->  claude-agent-acp
                                   |                      gh copilot --acp
                                   |                      grok --acp
                                   +-- transcripts/*.jsonl
agent --MCP over HTTP--> app on 4747 --> FileStore
```

The MCP half does not move. The agent still signs every call with the session the
factory gave it, still claims tasks, still files artifacts, still raises escalations.
What changes is the other direction: today the factory learns what an agent is doing
from an OSC title and a bell, and after this it is told.

## Stage 1: the client, in the package, with tests

`ACP` in `SoftwareFactoryKit`, Foundation only, the same shape as `MCPServer`: codable
message types and a `handle` that is pure per message. We write it ourselves. There is
no official Swift SDK and the community ones are a coin flip on still existing next
year; `MCPServer` is thirteen hundred lines of JSON-RPC 2.0 that we already maintain.

- `initialize`, `authenticate`, `session/new`, `session/load`, `session/prompt`,
  `session/cancel`.
- `session/update` notifications: agent message chunks, tool calls and their status,
  diffs, plans.
- `session/request_permission`.
- Client capabilities declared as `fs: false`, `terminal: false`. These agents are local
  CLIs with their own file tools and their own shell. Serving files back to an agent
  running in the same folder buys nothing and is a third of the protocol.
- `ACPTranscript`: the event stream reduced to something a page can draw. Turns, tool
  calls with a state, diffs as diffs, the plan as a checklist. This is the thing that
  replaces scrollback, so it is the thing to get right, and it is testable without a
  process anywhere near it.

Tests first, as always. A recorded session from a real `claude-agent-acp` run, replayed
through `ACPTranscript`, is the fixture.

**Before any of this**: check that Copilot, Grok and Cursor actually ship an ACP mode
today. The registry lists them; the registry is not a release note. Claude Code through
Zed's adapter is the only one worth building on unverified. If the other three are not
there, ACP is a Claude Code feature and the plan shrinks to match.

## Stage 2: the daemon

A verb on the CLI we already ship: `software-factory agentd`.

- Spawns an agent in the project's folder, in the person's own environment, and holds
  its pipes. One child per agent. No restart policy: an agent that died is stopped, and
  the floor already knows what to do with a stopped agent.
- Appends every ACP message to `~/.local/state/software-factory/transcripts/<agent>.jsonl`
  as it goes. A client that attaches gets the file and then the stream, which is how the
  agent page shows what happened while the app was being rebuilt.
- Talks to the app over a unix socket at `~/.local/state/software-factory/agentd.sock`,
  newline-delimited JSON: `attach`, `list`, `start`, `prompt`, `cancel`, `stop`,
  `permission`. A socket rather than a port, so the file permissions are the whole
  access story and there is no browser origin to refuse.
- The app spawns it detached when it is not answering, and we write a launchd LaunchAgent
  so it comes back after a logout or a crash.
- Direct download only, the same as tmux today. In the store build the app cannot spawn
  it, so ACP is simply not available there and the clipboard path stays exactly as it is.

This stage is the risk. A process we own that must not leak children, must not wedge,
and must be debuggable at two in the morning. Budget for it accordingly, and give it a
`software-factory agentd --status` that prints what it is holding.

## Stage 3: the launch path

- `LaunchAgent.acpCommand` beside `command(for:session:)`: the binary and its arguments
  for an ACP-speaking launch. `command(for:)` stays for Terminal, which is a shell and
  has nothing to do with any of this.
- `StartAgent.run` asks the daemon instead of `TerminalSessions`. Everything before that
  line stays: the cap, the reservation, the number, the assignment, remembering the kind.
- **The session id changes hands.** The agent mints it at `session/new`. `Agent.id` stays
  the record key and stays what the words tell the agent to sign its MCP calls with;
  `Agent.acpSessionID` sits beside it. This is the compromise Cursor already forced in
  T206 and it has been fine. The rule in CLAUDE.md gets a footnote, not a rewrite.
- `session/new` takes `mcpServers`, so the factory hands the agent its own MCP server at
  launch, pointed at 127.0.0.1:4747. `LaunchAgent.setupCommand` and the whole
  `claude plugin marketplace add` dance goes.
- An `Agent.runtime` of `terminal`, `acp` or `external`, so both paths run side by side
  for a release and nothing on the floor has to be killed to ship this.

## Stage 4: the agent page

The payoff, and the reason to do it at all.

- `AgentTranscript` replaces `TerminalPanel` in the left column. The agent's turns, its
  tool calls with a state each, diffs drawn as diffs, the plan as a checklist that ticks
  itself off. The page says what the agent is doing instead of showing a picture of the
  agent saying so.
- The field at the bottom is `session/prompt`. Nudge, messages and the status report ask
  all go through it: `AgentMessage.terminalLine` becomes the prompt text, `sendLine`
  returning false becomes "the daemon has no live session for this one", and the
  `delivered` rule survives unchanged, because it was always "did anything take it".
- The OSC title goes. `AgentLine.underTheName` reads the agent's last message or its
  current tool call, which is what the title was a worse version of.
- The bell goes, and `Agent.bel` stays. It is set by a permission request arriving, which
  is a far better reason to want a look than a CLI deciding to ring.
- `Tmux.holding`, `PaneTitles`, the `alert-bell` hook, `bellsRung`,
  `TerminalSessions.agentPID`: all of it was a way of learning something the protocol
  now tells us. It goes with the runtime it belonged to.

## Stage 5: permissions, which is the part that can go wrong

`session/request_permission` becomes an `Escalation` with the options it carries, on that
agent's project. Needs you, the phone banner and the Lock Screen already work, and this
is what they were built for.

The trap: an ACP permission request blocks the agent until it is answered. An escalation
nobody looks at for two hours is an agent that has done nothing for two hours, and today
every agent launches with the flag that turns asking off precisely because there was
nobody to ask. So:

- A Settings choice, three positions: allow everything, ask about writes and commands,
  ask about everything. **Allow everything is the default**, because that is today's
  behaviour and nothing should get slower on the day this lands.
- A timeout on any permission escalation that takes the recommended option and says in
  the decision that nobody answered.
- Reads and searches are never asked about at any setting.

## Stage 6: stop, start, and the sweeps

- Stop is `session/cancel`, then terminate the child. The transcript stays on disk, so
  what the agent last said is still readable, which is what leaving the pane did.
- Start is `session/load` when the agent advertises it, `session/resume` when it
  advertises that, and a fresh session carrying the old words when it advertises neither.
  Capability-gated, which is the protocol doing what `--resume` and a guess did.
- `Agent.hasExited` asks the daemon rather than the kernel, for an ACP agent. `pid`,
  `pidStartedAt` and `ProcessCheck` stay for external agents, which are the only ones
  left that the factory cannot see directly.
- `Sweep.stoppedAgents`, `idleAgentsToStop`, `agentsToPoke`, `statusReportsWanted`: no
  change. They read records, and the records still say the same things.

## What survives

SwiftTerm and tmux do not leave the tree. They shrink to the one thing they are for:
`LaunchAgent.terminal`, a shell in the project's folder that shows up on the floor. The
person keeps a window they can type into by hand, which the brief was right to call a
real loss and not a tidy-up. Under this plan it is not lost, it is just no longer how
agents run.

## Order, and what each one is worth on its own

1. Verify which of the four CLIs speak ACP today. Investigate, change nothing.
2. `ACP` types and `ACPTranscript` in the package, with a recorded fixture. Useful alone:
   it is the client for attaching to agents started outside the app, which is what the
   brief already recommended doing first.
3. `software-factory agentd`, holding one hard-coded agent, printing its transcript.
4. The socket protocol and attach/replay.
5. `Agent.runtime`, `LaunchAgent.acpCommand`, `StartAgent` through the daemon, one kind
   only, behind a Developer toggle.
6. `AgentTranscript` on the agent page.
7. Prompt, so nudges and messages go through ACP.
8. Stop and Start through the protocol.
9. Permission requests as escalations, with the default set to allow everything.
10. Retire the title, the bell hook and the pane-pid route for ACP agents.
11. The other three CLIs, if step 1 said yes.

Steps 1 and 2 are worth doing whatever happens to the rest. Step 3 is where this stops
being reversible, and is the point to decide again.
