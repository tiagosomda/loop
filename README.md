# dev-loop

An experiment in agent-driven development: write action items (bugs, tasks,
features) to a Firestore-backed board, and a locally scheduled,
provider-neutral orchestrator routes them to an enabled worker, works across
the repos under `dev/`, and writes results back to the board. See
[docs/design.md](docs/design.md).

The enabled workers are Codex for general implementation work and the locally
hosted Gemma 3 4B model for small, low-risk inspections and single-file edits.
Claude Code remains implemented but disabled in the target catalog.

## Layout

- `src/frontend` — Flutter web board UI, deployed to <https://tiago.dev/loop>
- `src/backend` — Python CLI for board I/O, repo crawling, and Firestore rules management
- `docs/` — design + the scheduled agent's runbook
- `data/` — local cache/scratch (gitignored)
- `dev` — symlink to the root folder containing all project repos (gitignored)

## Setup

```bash
# 1. symlink your projects root
ln -s ~/dev dev

# 2. backend deps
python3 -m venv src/backend/.venv
src/backend/.venv/bin/pip install -r src/backend/requirements.txt

# 3. service account for project tiago-dev-site
#    put it at data/service-account.json (or set $DEV_LOOP_SERVICE_ACCOUNT)

# 4. frontend
cd src/frontend && flutter pub get && flutter run -d chrome
```
