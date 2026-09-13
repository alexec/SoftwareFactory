# Taktu: Software Factory plugin

Connect Claude Code or GitHub Copilot CLI to the Taktu: Software Factory app running on this
Mac. The plugin supplies the local MCP connection and the `work-the-factory` skill.

## Before you begin

Open Taktu: Software Factory on the Mac. Its MCP server must be listening on port 4747.

## Claude Code

To try the plugin from this checkout:

```bash
claude --plugin-dir ./Plugins/software-factory
```

After publishing this repository, install it for reuse:

```bash
claude plugin marketplace add alexec/SoftwareFactory
claude plugin install software-factory@software-factory-plugins
```

## GitHub Copilot CLI

After publishing this repository, install the plugin from its subdirectory:

```bash
copilot plugin install alexec/SoftwareFactory:Plugins/software-factory
```

## Start work

In a new agent session, send:

```text
Use Taktu: Software Factory. Register with it, call project_get and read that project's
description and instructions before creating or changing a task, then take the next task
from a project that is not on hold, claim it, and start without asking for approval. Complete the board in
its listed order, unless work is already in progress, blocked, or factory capacity
says to wait. Follow the factory's lease, escalation, and completion rules.
```

## Coming soon

Codex and Cursor support will be added when their plugin packaging formats can load this
local MCP connection and shared skill.
