# What an agent tells us about itself, and what we throw away

A83, 16 September 2026. A brief, for Alex's "provide a way to view commands (if ACP
supports that) so we can understand how the agent is configured".

Measured off the 44 transcripts on this Mac rather than read out of the protocol docs,
which is the house rule and which paid off here: one of the things ACP.swift says we
cannot have, we are already being sent.

**One caveat before anything else.** Every log on this Mac is Claude Code's adapter,
`@agentclientprotocol/claude-agent-acp` 0.78.0. Grok, Copilot and Cursor are not on the
floor to check, and ACP lets an agent send none of this. Anything built here has to say
"it did not tell us" rather than assume, the same way `AgentProfile` already answers yes,
no or not tried.

## What arrives now

### 1. The commands, and the three things we drop

`available_commands_update` is already folded into `Running.commands` and already drawn
twice: the Commands menu under the field, and the slash row above it. One agent listed
**84 commands**. What we keep is the name and the first sentence. What we drop:

- **The list changes during a session.** One agent got five of these updates and went 84,
  81, 81, 81, 81. Something loads and unloads commands while it works, and nothing on the
  floor says so.
- **`input.hint`**, on 21 of the 84: the arguments a command takes. `/loop` carries
  `[interval] [prompt]`, `/code-review` carries
  `[low|medium|high|xhigh|max|ultra] [--fix] [--comment]`. We show a name and nothing about
  how to use it, which is most of what somebody wants from a list of commands.
- **Where the command came from.** The descriptions end `(user)` or
  `(project sessions only)`. That is the configuration question asked and answered, and it
  is sitting in the last twelve characters of a string we truncate.

The descriptions are whole paragraphs, because these are skills rather than one-line
commands. `Command.brief` takes the first sentence for a menu row, so nine tenths of what
the agent said about itself is never on screen anywhere.

### 2. `configOptions`, which we do not read at all

The `session/new` result carries a `configOptions` array. The audit at the top of
`ACP.swift` says of it: "newer than what we read." **That is out of date.** The adapter
we are talking to sends it today, on every session. Four options, each with an id, a name,
a description, a category, a type, a current value and its choices:

| id | what it is | now | choices |
| --- | --- | --- | --- |
| `mode` | session permission mode | default | default, acceptEdits, plan, auto, bypassPermissions |
| `model` | which model | default | default, opus[1m], claude-fable-5-1[1m], sonnet, haiku |
| `effort` | effort level for this model | default | default, low, medium, high, xhigh, max |
| `fast` | fast mode | off | on, off |

Two of those we handle by other means and two are invisible. `mode` we already read from
the separate `modes` field. `model` we choose at launch with a per-CLI flag, and the
reason written down in T462 is that "model selection is not in the version we target" —
it is now. `effort` and `fast` are not exposed anywhere in the factory, and an agent
running at `low` effort against an agent running at `max` is the sort of thing you would
want to see on a floor of sixteen.

### 3. The handshake

`agentInfo` gives a name and a version. `agentCapabilities` gives `loadSession`,
`promptCapabilities`, `mcpCapabilities`, `authMethods`, and a `sessionCapabilities` block
listing `additionalDirectories`, `close`, `delete`, `fork`, `list`, `resume` and
`subagents`. `AgentProfile` writes some of this down by hand, from measurement; the agent
answers a good deal of it itself, every time it starts.

### 4. `session_info_update`

Carries a `title` the agent gives the conversation, and an `updatedAt`. One agent called
its session "Stormy Night backlog". We ignore it. It is a better line for a card than the
OSC title ever was.

### 5. What is never sent

`current_mode_update` appears **zero times** in 44 logs. That confirms the note already in
`ACP.swift`: a `set_mode` is not echoed back, so the factory cannot tell whether one took.

## What to build

**A. An "How it is set up" panel on the agent's page.** Recommended. There are already two
icons above the side column, for documents and for a shell; this is a third. On it: the
agent's name and version, the config options with their current values, what the session
can do, and the commands in full, each with its arguments and where it came from. Every
byte of it already arrives and nothing new is asked of the agent. It answers the question
as asked: how is this agent configured.

**B. The commands alone, in full.** Smaller. A page listing every command with its whole
description, its `input` hint and its origin. Answers "what can I ask it to do" and not
"how is it set up".

**C. Read `configOptions`, and make them settable.** A separate and larger piece of work,
and the one with the most in it: `effort` and `fast` are not reachable today, and `model`
is chosen by a launch flag this supersedes. It needs a method for setting one, and I have
not confirmed ACP has such a method, because nothing in our logs ever sets one. That is a
spike before it is a task.

My recommendation is A now and C filed behind it, because A is reading what we already
have and C is a new conversation with four different CLIs.

## What it costs

Nothing on the wire. All of it is already in the transcript or in the handshake, so the
work is keeping two more things on `Running` (`configOptions`, `info`) and drawing a
panel. The commands are already there in full; only the drawing throws them away.
