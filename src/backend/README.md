# dev-loop backend

Python CLI the scheduled agent (and the user) uses to talk to the board.
Uses the Firebase Admin SDK with a service account for project
`tiago-dev-site`, so it bypasses security rules — everything it touches is
scoped under `dev-loop/` in the shared database.

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
# credential: $DEV_LOOP_SERVICE_ACCOUNT, or ../../data/service-account.json
```

## Usage

```bash
.venv/bin/python devloop.py items list --status open,in-progress
.venv/bin/python devloop.py items claim <id>       # before starting work
.venv/bin/python devloop.py items post <id> --text "results..." --attach out.png
.venv/bin/python devloop.py items status <id> needs-review
.venv/bin/python devloop.py repos crawl            # sync dev/ repos to Firestore
.venv/bin/python devloop.py schedule update --mark-run
.venv/bin/python devloop.py targets list --role worker --enabled-only
.venv/bin/python devloop.py route decide <item-id> --shadow
.venv/bin/python devloop.py run autonomous --max-items 1
```

The target catalog lives in `config/targets.json`. Provider and model choices
are data-driven: safe projections omit command paths and local endpoints, and
`--enabled-only` excludes disabled providers such as Claude. Codex is the
configured fallback. The enabled Local Gemma worker shares the supervised
llama.cpp endpoint with the router and is intended only for small, low-risk
tasks. Its trusted adapter exposes bounded file inspection, validated patches,
network-denied checks, and deterministic commit/push delivery rather than a
general model-controlled shell.

Local scheduling and llama-server supervision are documented in
`../../ops/launchd/README.md`. Provider-owned schedules are not part of the
autonomous workflow.

## Shared security rules — read before touching

The Firestore (and Storage) ruleset is shared with other projects. Our rules
live in `rules/dev-loop.rules` between `// === dev-loop rules start/end ===`
markers. To update:

```bash
.venv/bin/python devloop.py rules pull     # download the FULL deployed set
.venv/bin/python devloop.py rules merge    # splice our section in
.venv/bin/python devloop.py rules deploy   # release the FULL merged set
# same for storage rules: add --service storage to each command
```

Never deploy a rules file that contains only the dev-loop section — it would
wipe every other project's rules.
