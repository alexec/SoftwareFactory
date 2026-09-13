# Software Factory Copilot Instructions

## Build and test

`project.yml` is the source of truth. Regenerate the ignored Xcode project after changing it:

```bash
xcodegen generate
```

Immediately before an `xcodebuild`, check whether the Mac is available. Do not build if it is claimed:

```bash
bash ~/.claude/skills/task-board/assets/machine.sh --brief
```

Build the macOS app:

```bash
xcodebuild -project SoftwareFactory.xcodeproj -scheme SoftwareFactory -configuration Debug \
  -destination "platform=macOS" -derivedDataPath build/DerivedData build
```

Build the iPhone app:

```bash
xcodebuild -project SoftwareFactory.xcodeproj -scheme SoftwareFactoryPhone -configuration Debug \
  -destination "generic/platform=iOS Simulator" -derivedDataPath build/DerivedData build
```

The Foundation-only package owns the test suite:

```bash
cd Packages/SoftwareFactoryKit && swift test
cd Packages/SoftwareFactoryKit && swift test --filter BacklogTests
cd Packages/SoftwareFactoryKit && swift test --filter MCPServerTests/numbersAreShortUniqueAndUsableAsIds
```

There is no separate lint command configured.

## Architecture

Software Factory is a sandboxed macOS SwiftUI app that runs an MCP/HTTP server on port
4747, plus an iPhone SwiftUI remote. Coding agents register with the factory, work
project backlogs, lease shared resources, and raise escalations for the person to decide.
The Mac advertises the server as `_softwarefactory._tcp`; the phone discovers it over
Bonjour and uses the package's HTTP API.

`Packages/SoftwareFactoryKit` is the product's domain and protocol layer. It is
Foundation-only and contains records, atomic JSON `FileStore` persistence, backlog and
lease rules, capacity decisions, dashboard derivation, MCP JSON-RPC, and the HTTP router.
It also builds the `software-factory` command-line executable, whose `mcp` command serves
the same protocol over stdio. Put product rules here, test them here, and keep the app
targets as clients of those rules.

`App/Sources` is the thin macOS shell. `AppModel` owns the store, refreshes it, derives
the dashboard, runs `FactoryServer`, and synchronizes through `Shared/CloudSync.swift`.
`Phone/Sources` discovers the local factory and polls `/api/snapshot`; when the factory is
unavailable it reads and writes through the same private CloudKit store. `Shared/` holds
code compiled by both apps, including CloudKit sync, dictation, and task title parsing.
The iOS widget extension reuses `Phone/Activity` for Lock Screen and Dynamic Island
decisions.

The shared store is the integration boundary: one atomically written JSON file per record.
The sandboxed app normally uses its app-group container; set `SOFTWARE_FACTORY_STORE` to
use another store for the app or CLI.

## Repository conventions

- Keep decision-making out of views. New rules belong in `SoftwareFactoryKit` with a
  Swift Testing test before a SwiftUI surface uses them.
- Records are `Codable`, `Sendable`, and `Equatable`. Treat their JSON as an API shared by
  the macOS app, MCP server, CLI, and iCloud clients: preserve a reader for every older
  shape, and bump `Records.version` if an older reader cannot decode the new shape.
- Add an MCP tool in both `Tool.all` and `MCPServer.call(_:_:)`, with coverage in
  `MCPServerTests`. Keep `MCPServer.handle(_:)` pure for each request.
- Work that runs on network or audio threads must be `@Sendable` and must not access
  main-actor state. Bridge back to `@MainActor` explicitly.
- The person, not the app, decides escalations. Agents report task progress; people may
  directly set only backlog and parked tasks. The board is work the person expects
  agents to complete, in its listed order where possible. Claim and start an available
  task without requesting approval; depart from the order only for work already in
  progress, a blocker, or a factory capacity instruction.
- Project names are the user-facing identity. Project resolution accepts a name, UUID, or
  legacy folder path, and must refuse a near-match unless `project_add` uses `force`.
- Preserve the local-first and private design: the app only exposes the local MCP/HTTP
  service; cross-device synchronization is through the person's private iCloud container.
- Use Alex's direct UI voice. Every person-facing string says why when useful and never
  uses an em dash. Keep the first-run explanation in the intro sheet rather than adding
  instructional copy throughout screens.
- `DEBUG` controls the Settings developer section. Keep it defined only in the Debug
  configuration in `project.yml`.
