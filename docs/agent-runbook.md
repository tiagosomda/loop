# dev-loop agent runbook

Procedure for the scheduled agent run (00:15 / 05:15 / 10:15 / 15:15 / 20:15
local). Only one agent runs at a time.

All board commands run from `src/backend` in the dev-loop repo:

```bash
PY=src/backend/.venv/bin/python
CLI=src/backend/devloop.py
```

## 1. Start of run

```bash
$PY $CLI schedule update --mark-run
$PY $CLI repos crawl
$PY $CLI items list --status open,in-progress
```

## 2. Triage

- For each `in-progress` item: it was claimed by a previous run that likely
  timed out. Check `lastAgentRunAt`; look in the item's repo (under `dev/`,
  see the repo's `path` in the repos registry) for a work-in-progress branch,
  uncommitted changes, or an open PR related to the item. Resume that work if
  it exists; otherwise treat the item as fresh.
- Group related items when it makes the work better/cheaper — but every item
  still gets its own status updates and thread messages.
- Respect an item's `model` and `effortLevel` hints when spawning sub-work.

## 3. Per item

1. **Claim first** (before any work, so a timeout leaves a truthful state):
   ```bash
   $PY $CLI items claim <id>
   ```
2. Read the full thread for context:
   ```bash
   $PY $CLI items show <id>
   ```
3. Do the work in the item's repo under `dev/`, using best-practice agentic
   workflows: branch, implement, test, commit; open a PR when the repo has a
   remote workflow that fits.
4. Write results back — always. Include what was done, where (branch/PR
   links), what's left, and anything the user must decide. Attach files or
   screenshots when they help:
   ```bash
   $PY $CLI items post <id> --text "..." --attach path/to/file.png
   ```
5. Set the final status:
   - `needs-review` — user input or review is required (default for code
     changes),
   - `completed` — done and verified, nothing for the user to decide.
   ```bash
   $PY $CLI items status <id> needs-review
   ```
   Never set `closed` — closing is the user's call.

## 4. End of run

- Make sure no item you touched is still `in-progress` unless you are
  intentionally handing it to the next run (say so in its thread).
- Cache/state you want to persist between runs goes in `data/`.
