# ACP, and whether the factory should speak it

A brief. T367, 16 Sep 2026.

The Agent Client Protocol is what LSP is for language servers, for coding agents: the
editor stops caring which agent it is talking to. It is JSON-RPC 2.0 over stdio, the
agent runs as a subprocess of the client, and there is an HTTP and WebSocket transport
marked work in progress. It reuses MCP's JSON shapes where it can and adds the things a
coding UI needs: tool calls, diffs, plans, permission requests.

## The short answer: all four of ours speak it

Every coding agent this factory launches is in the registry.

| Ours | In ACP as | How | Launch |
|---|---|---|---|
| Claude Code | Claude Agent | Zed's adapter on Anthropic's Claude Agent SDK | `claude-agent-acp` |
| GitHub Copilot | GitHub Copilot | First-party, in public preview | `gh copilot` |
| Grok | Grok Build | First-party, xAI | `grok` |
| Cursor | Cursor | First-party | `cursor` |

Terminal is a shell and has nothing to do with this.

Forty-odd others are listed, Gemini CLI, Codex, OpenCode, Goose, Qwen Code, Junie,
Kiro, OpenHands. Adding an agent kind would stop being a code change and become a row in
a list, which is the whole point of the protocol.

## What we would gain

- **The agent's work as data.** Today an agent's page is a terminal, and everything the
  factory knows about what is happening inside it comes from an OSC title and a bell. ACP
  hands over tool calls, file diffs and plans as structured events. The agent page could
  say what it is doing rather than showing a picture of it saying so.
- **Permission requests to answer.** The agent asks the client before it does something.
  The factory already has somewhere to put that question: `Escalation`, the Needs you
  strip, the phone, the Lock Screen. Today we launch every agent with the flag that turns
  asking off, because there is nobody on the other end to ask.
- **MCP without the plugin dance.** `session/new` takes `cwd` and `mcpServers`. The
  factory could hand an agent its own MCP server at launch, and `LaunchAgent.setupCommand`
  with its `claude plugin marketplace add` could go.
- **Sessions the protocol understands.** `session/load` replays a conversation and
  `session/resume` picks it up without replaying, both across a client restart, both
  capability-gated. That is Start on a stopped agent, done properly rather than with
  `--resume` and a guess.

## What it would cost, and this is the one that matters

**An ACP agent is a subprocess of its client. When the client dies, the agent dies.**

The factory's most useful property is the opposite of that. tmux owns the process, the
agent outlives the app, and every rebuild and restart, a dozen a day, leaves eight agents
working. Rebuild the app under ACP and every agent on the floor goes with it.

The remote transport would fix this, and it is work in progress. A local bridge holding
the subprocess and speaking WebSocket to the app would fix it too, and that bridge is
tmux's job rewritten by us, badly, in a place we do not want to own.

Smaller costs:

- **No official Swift SDK.** Rust, TypeScript, Kotlin, Java, Python. There are at least
  five community Swift packages and no way to tell which will exist in a year. Writing the
  client ourselves is not far-fetched: `MCPServer` already speaks JSON-RPC 2.0 and the app
  already spawns processes and reads pipes. But it is a client, and everything we have
  written so far is a server.
- **The session id changes hands.** "The session is the agent" is one UUID doing four
  jobs, and the factory makes it before it launches anything. Under ACP the agent makes
  the id and hands it back. We would keep `Agent.id` as the record key and store the ACP
  id beside it, which is exactly the compromise Cursor already forced (T206) and it has
  been fine.
- **No typing to it.** Nudge types a line into a terminal. Under ACP that is
  `session/prompt`, which is better. But the person losing a terminal they can type into
  by hand is a real loss, not a tidy-up.

## What I would do

Not now, and not never.

The thing to watch is the remote transport. Until an ACP agent can outlive the client
that started it, adopting ACP means trading the one thing that makes this floor work for
a nicer agent page, and that is a bad trade.

What is worth doing before then is small and useful on its own: keep the terminal as it
is, and add ACP as a second way an agent can be attached, for an agent started outside
the app. The factory already has that idea: `Agent.isEmbedded` is false for an agent that
registered from somewhere else, and it says outright that there is nothing to watch or
stop. An ACP connection would give those agents a page worth opening.

## Sources

- https://agentclientprotocol.com
- https://agentclientprotocol.com/get-started/agents
- https://agentclientprotocol.com/get-started/registry
- https://agentclientprotocol.com/protocol/v1/session-setup
- https://github.com/zed-industries/claude-agent-acp
