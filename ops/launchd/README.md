# Local dev-loop services

The workflow is owned by two user LaunchAgents, not by Codex or Claude
schedules:

- `com.devloop.llama-server` keeps the local Gemma router available on
  `127.0.0.1:8080` and restarts it after a crash.
- `com.devloop.orchestrator` runs `devloop run autonomous` at 00:15, 01:30,
  05:15, 10:15, 13:15, 15:15, 17:15, and 20:15 machine-local time. The published schedule
  interprets these slots in `DEV_LOOP_SCHEDULE_TIMEZONE` (default:
  `America/New_York`) and exposes upcoming UTC instants for viewer-local UI.
- `com.devloop.self-healing` runs at 08:15 machine-local time. It inspects new
  scheduler failures since its prior inspection, creates a diagnostic board
  item when needed, attempts a safe repair, and always leaves that item in
  `needs-review`. It never consumes the normal board queue.

## Prerequisites

1. Install `llama.cpp` and verify `/opt/homebrew/bin/llama-server`.
2. Create `src/backend/.venv` and install `src/backend/requirements.txt`.
3. Put the Firebase service-account JSON at
   `data/service-account.json` (gitignored), or edit the orchestrator plist to
   set `DEV_LOOP_SERVICE_ACCOUNT` to an absolute credential path.
4. Authenticate the `codex` CLI for the macOS user running these agents.
5. Stop any manually started server already using port 8080.

## Install

```bash
mkdir -p ~/Library/LaunchAgents
install -m 644 ops/launchd/com.devloop.llama-server.plist \
  ~/Library/LaunchAgents/com.devloop.llama-server.plist
install -m 644 ops/launchd/com.devloop.orchestrator.plist \
  ~/Library/LaunchAgents/com.devloop.orchestrator.plist
install -m 644 ops/launchd/com.devloop.self-healing.plist \
  ~/Library/LaunchAgents/com.devloop.self-healing.plist

launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/com.devloop.llama-server.plist
launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/com.devloop.orchestrator.plist
launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/com.devloop.self-healing.plist
```

Use `launchctl kickstart -k gui/$(id -u)/com.devloop.llama-server` or the
corresponding orchestrator label for an immediate run. Calendar invocations
are protected by `data/agent-runs/orchestrator.lock`; overlaps exit without
starting a second queue worker.

## Verify and inspect

```bash
curl http://127.0.0.1:8080/health
launchctl print gui/$(id -u)/com.devloop.llama-server
launchctl print gui/$(id -u)/com.devloop.orchestrator
tail -f data/llama-server.error.log data/orchestrator.error.log
```

For a bounded manual workflow check:

```bash
src/backend/.venv/bin/python src/backend/devloop.py run autonomous --max-items 1
```

## Disable or roll back

```bash
launchctl bootout gui/$(id -u)/com.devloop.orchestrator
launchctl bootout gui/$(id -u)/com.devloop.llama-server
rm ~/Library/LaunchAgents/com.devloop.orchestrator.plist
rm ~/Library/LaunchAgents/com.devloop.llama-server.plist
```

Disabling the LaunchAgents does not change board items, run records, Git
checkouts, or downloaded model files.
