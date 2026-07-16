# dev-loop — Design

## What is this?

dev-loop is an experiment in autonomous, agent-driven development. The user
writes **action items** (bugs, tasks, features, ideas) to a **board**. A
**scheduled agent** (Claude Code scheduled task) wakes up periodically, pulls
the open items from the board, works on them across the user's repos using
best-practice agentic workflows, and writes results back to the board. The
user reviews the results and has the final call on closing items.

```
┌───────────────┐      writes items       ┌─────────────────────┐
│  Web frontend │ ──────────────────────▶ │  Firestore board    │
│ tiago.dev/    │ ◀────────────────────── │  /dev-loop/**       │
│   loop        │      reads status        └────────▲───────────┘
└───────────────┘                                   │ reads open items,
                                                    │ writes updates
                                          ┌─────────┴───────────┐
                                          │  Scheduled agent    │
                                          │  (Claude Code, ~5h) │
                                          │  works in dev/*     │
                                          └─────────────────────┘
```

## Core concepts

### Action item

A message thread with metadata. Two layers in Firestore to keep board
queries cheap:

- **Summary doc** (small, listed on the board): id, title, repo, status,
  optional model + effort level, created/modified timestamps, message count.
- **Thread** (full content, loaded only in the detail view): one document per
  message, in a subcollection. Messages can carry file/image attachments —
  both user messages and agent messages.

### Statuses

| Status | Set by | Meaning |
|---|---|---|
| `open` | user | Ready to be picked up |
| `in-progress` | agent | Claimed **before** work starts (crash-safe: a later run sees a stale `in-progress` item, checks its timestamp/worktree, and resumes or restarts) |
| `needs-review` | agent | Work done, user input needed |
| `completed` | agent | Work done, agent considers it finished |
| `closed` | user | User has the final call — only the user closes items |

### Scheduled agent loop

- Runs roughly every 5 hours at **:15**, same times every day:
  **00:15, 01:30, 05:15, 10:15, 13:15, 15:15, 17:15, 20:15** in the configured
  `America/New_York` scheduler timezone. Firestore also receives upcoming UTC
  instants so the frontend can display them in the viewer's local timezone.
- Procedure per run (see `docs/agent-runbook.md`):
  1. Pull items with status `open` or `in-progress`.
  2. For stale `in-progress` items: check how old the claim is and whether
     there is work in progress in the repo before starting over. (Only one
     agent runs at a time — no locking needed beyond the status field.)
  3. Mark an item `in-progress` **before** starting on it.
  4. Work on it in the target repo under `dev/`. Grouping related items is
     fine, but every item gets its own status write-back.
  5. Post a thread message with useful results/context (attachments allowed),
     then mark `needs-review` or `completed`.

## Firestore data model

Shared database (project `tiago-dev-site`, default database). **Everything
lives under a single root-level document path `dev-loop/app`** so it coexists
with the other projects (match-chat, etc.). Access is hardcoded to
`tsomda@gmail.com`.

```
dev-loop/app                                   root doc (app metadata)
dev-loop/app/items/{itemId}                    action-item summary docs
    title, repoId, status, model, effortLevel, order (manual board position),
    createdAt, updatedAt, lastAgentRunAt, messageCount
dev-loop/app/items/{itemId}/messages/{msgId}   thread messages (own docs)
    author ("user" | "agent"), text,
    attachments: [{name, storagePath, contentType, size}], createdAt
dev-loop/app/repos/{repoId}                    crawled repos
    name, path, remote, host ("github"|"gitlab"),
    status ("active"|"removed"), lastSeenAt
dev-loop/app/meta/schedule                     agent schedule info
    times: ["00:15", ...], sessions: [{kind, time}], timezone,
    nextRunsAt, nextSessions: [{kind, startsAt}], lastRunAt, updatedAt
```

Attachments are stored in Firebase Storage under
`dev-loop/attachments/{itemId}/{msgId}/{filename}`; message docs hold only
the storage path + metadata.

### Security rules (shared ruleset!)

The Firestore ruleset is **shared with other projects**. Our rules live in a
clearly-marked section scoped to `/dev-loop/**` and grant access only when
`request.auth.token.email == 'tsomda@gmail.com'`. Updating rules is always:

1. **Pull** the currently deployed ruleset (never trust a local copy),
2. **Replace only the dev-loop marker section** (insert if absent),
3. **Deploy the entire merged set** back.

The backend has a script for this (`rules pull/merge/deploy`). Never run a
plain `firebase deploy --only firestore:rules` from a file that contains only
dev-loop rules — it would wipe the other projects' rules.

The backend agent itself uses the **Admin SDK** (service account), which
bypasses rules.

## Repo layout

```
dev-loop/
├── dev -> ~/dev              symlink to the root of all projects (gitignored,
│                             machine-specific; each project has its own repo)
├── data/                     local cache / scratch about the board & repos
│                             (gitignored except .gitkeep)
├── docs/                     design.md, agent-runbook.md, ...
├── src/
│   ├── backend/              Python scripts (board I/O, repo crawl, rules)
│   └── frontend/             Flutter web app (the board UI)
└── .github/workflows/        GitHub Pages deploy
```

## Backend (`src/backend`)

Python 3 + `firebase-admin` (same approach as match-chat's poller; the
service account for project `tiago-dev-site` is reused). Single CLI entry
point, `devloop.py`, with subcommands:

| Command | What it does |
|---|---|
| `items list [--status open,in-progress]` | List summary docs (agent's first step; also writes a cache snapshot to `data/`) |
| `items claim <id>` | Set `in-progress` + `lastAgentRunAt` (call before working) |
| `items status <id> <status>` | Update status |
| `items reorder <id> <value>` | Set an item's manual board position (`order` field) — the frontend's drag-to-reorder writes gap-based values; this is the CLI escape hatch |
| `items post <id> --text ... [--attach file]...` | Append an agent message to the thread, uploading attachments to Storage |
| `items create --title ... --repo ...` | Create a new item (handy for testing) |
| `repos crawl` | Walk `dev/` for git repos → upsert into Firestore; repos no longer found are marked `removed` (hidden from the new-item picker, visible in profile until the user clears them) |
| `schedule update` | Write the run times to `dev-loop/app/meta/schedule` |
| `rules pull` | Download the deployed ruleset to `data/firestore.rules.current` |
| `rules merge` | Splice `rules/dev-loop.rules` into the pulled set between markers → `data/firestore.rules.merged` |
| `rules deploy` | Upload + release the merged ruleset (with confirmation) |

Service-account resolution order: `$DEV_LOOP_SERVICE_ACCOUNT` →
`data/service-account.json` → match-chat's poller copy.

## Frontend (`src/frontend`)

Flutter web (Dart), mobile-first, deployed via **GitHub Pages** to
`tiago.dev/loop` (the repo is a project page under the `tiago.dev`
github.io site — note: project-setup.md says "gitlab pages" but the repo and
the tiago.dev domain live on GitHub; following match-chat's proven GitHub
Pages workflow).

Design language: **minimalistic with a sci-fi/space vibe**. Dark, light and
follow-system themes. Lean on Material 3 + established packages
(`firebase_ui`-style flows, `provider`, `file_picker`, etc.) over custom code.

### Screens

- **Logged out**: centered "dev loop" header; theme + login (Firebase Auth /
  Google) buttons on the right. Brief blurb: this is tiago's dev-loop
  experiment → link to notes.tiago.dev.
- **Board (home)**: header with "dev loop" on the left; right side: **+**
  (new item), theme toggle, profile button.
  - **List view** and **kanban view** (columns per status), toggleable.
  - Search field + status/repo filters to find things fast.
  - Manual drag-to-reorder (list view, and within each kanban column) sets
    the board's order — this is also the order the scheduled agent picks
    items up in (see `run.py`'s queue), so there's no separate "sort by"
    control.
  - Item cards show brief info: title, repo, status, last modified.
- **New item**: dialog/sheet — title, repo picker (active repos only),
  optional model + effort level, first message with attachments.
- **Item detail (fullscreen)**: full thread, composer with file/image
  attachments, status changer, model/effort editing.
- **Profile**: log out; searchable list of all repos (including `removed`
  ones until cleared); the agent's scheduled wake-up times (from
  `meta/schedule`).

## Firebase

- Project `tiago-dev-site` (shared). Web config is committed in
  `firebase_options.dart` (public by design for web apps; security comes from
  rules).
- Auth: Firebase Auth with Google sign-in; rules only authorize
  `tsomda@gmail.com` regardless of who signs in.
- Storage bucket `tiago-dev-site.firebasestorage.app`, attachments under
  `dev-loop/…`; storage rules need the same pull/merge/deploy care if that
  ruleset is shared too.

## Task breakdown

1. **Repo scaffolding** — `.gitignore` (dev symlink, data cache, service
   accounts, build output), `data/.gitkeep`, README.
2. **Backend CLI** — Firestore access layer + the `items`, `repos`,
   `schedule` and `rules` subcommands; requirements.txt; README.
3. **Rules** — `rules/dev-loop.rules` section + merge/deploy scripts;
   deploy the merged ruleset once verified.
4. **Frontend** — Flutter app scaffold, Firebase wiring, theming, board
   (list + kanban + search/filter/sort), item detail thread with
   attachments, new-item flow, profile, logged-out landing.
5. **Deploy** — GitHub Pages workflow (`--base-href /loop/`).
6. **Agent loop** — `docs/agent-runbook.md` + Claude Code scheduled task at
   00:15/01:30/05:15/10:15/13:15/15:15/17:15/20:15; `schedule update` + `repos crawl` run at
   the end of setup and periodically thereafter.
7. **Later / nice-to-have** — thumbnails for image attachments, item
   labels/priorities, notifications when items hit `needs-review`, board
   cache in `data/` for faster agent startup.
