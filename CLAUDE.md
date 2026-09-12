# CLAUDE.md

Foreman is a sandboxed macOS 26 SwiftUI app (Liquid Glass) that shows what Claude Code
agents are doing across projects, the escalations that need the person's decision, and
each project's prioritised backlog. `README.md` has the pitch and the rules;
`CONTRIBUTING.md` the promise; `BACKLOG.md` what is planned and refused.

## Build

`project.yml` is the source of truth; `Foreman.xcodeproj` is generated and git-ignored.
The Debug/Release settings are spelled out under `configs:` because this xcodegen has no
presets; `DEBUG` gates the Developer section of Settings.

```bash
xcodegen generate
xcodebuild -project Foreman.xcodeproj -scheme Foreman -configuration Debug \
  -destination "platform=macOS" -derivedDataPath build/DerivedData build
cd Packages/ForemanKit && swift test
cd Packages/ForemanKit && swift build -c release --product foreman   # the CLI
open build/DerivedData/Build/Products/Debug/Foreman.app
```

Check `bash ~/.claude/skills/task-board/assets/machine.sh --brief` immediately before
`xcodebuild`; if the Mac is claimed, do not build.

## Shape

- `Packages/ForemanKit` (Foundation only, `swift test`):
  - `Models`: `Project` (id is the folder path), `WorkItem` (feature/bug/chore;
    backlog/inProgress/done; rank), `Escalation` (options, one recommended,
    `decide(_:)` records the choice), `AgentSession` (from Claude Code;
    `activity(now:)` is working/waiting/ended on a 90 s window).
  - `FileStore`: one JSON file per record under `projects/`, `items/`, `escalations/`;
    atomic writes; unreadable files skipped. `defaultRoot()` is the app group container
    or `$FOREMAN_STORE`.
  - `ClaudeCodeScanner`: reads `~/.claude/sessions/*.json` (running sessions, pid, cwd)
    and the tail of `~/.claude/projects/*/*.jsonl` (last cwd, last human prompt, mtime).
    Liveness is `sysctl`, which works inside the sandbox.
  - `Backlog`: order, next rank, move (onMove semantics), state changes, current item.
  - `Dashboard.make(snapshot:sessions:now:)`: counts and one `ProjectStatus` per project.
  - `SampleData`: records for a Debug build to look at.
  - `foreman` executable: `status`, `projects`, `project add`, `task list|add|start|done`,
    `escalate`, `escalations`, `decide`.
- `App/Sources`:
  - `AppModel`: `@Observable @MainActor`; refreshes every 5 s (store load + scan off
    main); every write goes through `persist`.
  - `ClaudeFolderAccess`: security-scoped bookmark to `~/.claude`, chosen once.
  - `RootView` (split view: Dashboard + projects), `DashboardView` (stat tiles,
    Needs you, Projects), `EscalationCard`, `ProjectView` (backlog with add, reorder,
    state menu), `IntroSheet` (first-run, three sections, one button), `SettingsView`
    (How it works on top, Claude folder, store, Developer in DEBUG).

## Rules for changes

- A rule goes in the package with a test before it goes in a view.
- Never write to `~/.claude`. Never change a record's JSON shape without a reader for the
  old shape.
- Every string a person reads follows `alex-writing-voice`; no em dashes.
- First-run: the sheet shows once (`hasSeenIntro`) and again from Settings. Reset with the
  Developer row or `defaults delete com.alexecollins.foreman hasSeenIntro`.
- Try the dashboard with data: Settings ▸ Developer ▸ Add sample data, or the `foreman`
  CLI against the same store.
