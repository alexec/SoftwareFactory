# What the four agents declare

A71, 15 September 2026. T428. Measured by handshaking each binary, not read out of the
protocol. One `initialize` down each pipe with the factory's own client capabilities, and
the answer written down as it came back.

```bash
python3 /tmp/acp-probe.py   # the script is at the foot of this file
```

Versions as measured: `@agentclientprotocol/claude-agent-acp` 0.78.0, Copilot 1.0.84-9,
Grok 1.0.30, Cursor (no version in its handshake).

## The grid

| | Claude Code | Copilot | Grok | Cursor |
| --- | --- | --- | --- | --- |
| image in a prompt | yes | yes | **no** | yes |
| embedded context | yes | yes | yes | **no** |
| audio | not said | no | no | no |
| MCP over http | yes | yes | yes | yes |
| loadSession declared | yes | yes | yes | yes, **and it refuses** |
| session close | yes | yes | yes | no |
| session list | yes | yes | yes | yes |
| session resume | yes | no | yes | no |
| session fork, delete, subagents, extra folders | yes | no | no | no |
| providers (model choice) | declared, empty | no | in `_meta` instead | no |
| authMethods | none | `copilot-login` | `cached_token`, `grok.com` | `cursor_login` |

**A declaration is not a measurement.** Every one of the four says `loadSession: true`, and
Cursor answers `session/load` with "Invalid params", which is why `AgentProfile` exists and
why its answers are yes, no and not tried rather than yes and no. Read this grid as what
they claim; `AgentProfile` is what they were caught doing.

## What is worth having

**Images in a prompt, T427: three of four, but not the one you would want.** Claude Code,
Copilot and Cursor take an image; Grok says no outright. `embeddedContext` is the mirror of
it: everyone but Cursor. So a prompt with a screenshot in it works on most of the floor and
has to degrade on the rest, and the factory's own field is the place it would go: drag a
screenshot onto an agent's page and it goes down as a prompt. That is worth building and
the refusal has to be per agent rather than a flag, because two different agents refuse two
different halves of it.

**Authentication, and nothing on this floor can do it.** Three of the four declare an auth
method and the factory never calls `authenticate`. Claude Code needs none here, which is
why nobody has noticed. A Copilot or Cursor agent that is not logged in fails at
`session/new` with no way in from the app, and Cursor's own note in `AgentProfile` says its
account needs a plan before it will do anything. This is the gap most likely to waste an
evening, and the smallest honest fix is not a login flow: it is for the failure to say
"Copilot is not logged in, run `copilot login`", which is exactly what its handshake hands
us in `_meta.terminal-auth`.

**Model choice, and Grok is the one that offers it.** ACP puts this under `providers`;
Claude Code declares the key and leaves it empty, and Grok puts a whole `modelState` in
`_meta` instead: `grok-4.6` and `grok-4.5`, with context sizes and reasoning efforts. So
picking a model per agent is possible on exactly one agent, through a vendor extension.
Worth knowing, not worth building until two of them agree.

**Available commands, dropped today.** An agent's own slash commands arrive as
`available_commands_update` and fall to `.other`, so the floor never shows what an agent
can be asked to do. Grok also lists them in `_meta.availableCommands` at handshake. Cheap
to read, and it is the only one of these that makes the app show something new about an
agent rather than doing something new to it.

**Session close, and we do not call it.** Three of four offer it. Stopping an agent kills
the process, which works and is blunt; `session/close` is the polite version and would let
a CLI write out whatever it keeps. Worth having behind the same Stop.

**What is declared and is not worth taking.** `fork`, `delete`, `subagents` and
`additionalDirectories` are Claude Code alone, which makes them a second way of doing
things for one quarter of the floor. Grok's hooks, tool overrides and voice mode are the
same argument in x.ai's words. `steering` (saying something mid-turn without cancelling)
is the interesting one and is also Claude Code alone: the queue in `AgentFloor` exists
because two of the four lose a mid-turn prompt, and one agent having a better way does not
remove the need for the queue.

## The probe

Kept here because the next person to ask this question should not have to write it again,
and because it is the only honest way to answer it: the documentation describes the
protocol and these four disagree with it in different places.

Each agent is started with its own ACP incantation, which is not the same shape twice:
`claude-agent-acp`, `copilot --acp`, `grok agent stdio`, `cursor-agent acp`. One
`initialize` with the client capabilities the factory really sends, one line read back,
kill the process. The script is `Tools/acp-probe.py`.
