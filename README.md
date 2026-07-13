# dev-loop

An experiment in agent-driven development: write action items (bugs, tasks,
features) to a Firestore-backed board, and a scheduled Claude Code agent picks
them up, works on them across the repos under `dev/`, and writes results back
to the board. See [docs/design.md](docs/design.md).

## Layout

- `src/frontend` — Flutter web board UI, deployed to <https://tiago.dev/dev-loop>
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
