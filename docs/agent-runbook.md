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
$PY $CLI run start    # mark-run (logs "run started") + repos crawl + ordered queue
```

`run start` returns `{"repos": {...}, "queue": [...items...]}` — the queue is
already ordered in-progress-before-open, then by the board's manual order
(section 2's ordering rule), so you don't need to re-derive it by hand.

**Run log** (`data/agent-runs.log`): every run must leave a trace, and the
mechanics of that are scripted so the trace can't be skipped by forgetting a
step:

- `run start` logs "run started" automatically.
- `items claim <id>` and `items status <id> <status>` each log their own
  transition automatically (`item <id> claimed`, `item <id> -> <status>`) —
  you don't call `runlog` for these.
- `run end [--note "..."]` logs the "run finished" line. Without `--note` it
  auto-summarizes which item ids were touched (claimed/status-changed) since
  the last "run started" line; pass `--note` to describe something the
  auto-summary can't capture (idle run, an intentional hand-off, an abnormal
  stop). Call it once at the end of every run, even an idle one.
- `runlog add "..."` still exists for anything else worth a trace mid-run
  (an abnormal event as it happens — rate limit, hand-off, failure) —
  `runlog tail` shows recent history when debugging.

A scheduled slot with no "run started" line means the run never executed at
all (e.g. the model was rate-limited before it could act); a "run started"
with no "run finished" means it died mid-run — check for stale in-progress
items (`run stale <id>`, section 2).

## 2. Triage

- **Refresh before every pick, not just at the start of the run.** `run
  start`'s queue is a snapshot; the user can add a new item or reply to an
  open thread while the run is in progress. Before claiming each item —
  including the first — call `run next` and act on whatever it returns
  (or `null` if the queue is empty) rather than working through the
  snapshot from step 1. `run next` re-queries Firestore and applies the same
  in-progress-before-open, then-manual-order ordering every time, so
  there's nothing to re-derive by hand. Manual order is the position the
  user drags items to on the board (list view or within a kanban column) —
  "what you see is what runs next." Items that predate manual ordering (no
  `order` field, never dragged) interleave among explicitly-ordered items by
  creation time, so they keep whatever relative position they'd visually
  have on the board rather than being bucketed to the back of the queue.
- For each `in-progress` item: it was claimed by a previous run that likely
  timed out. Run `run stale <id>` — it checks `lastAgentRunAt` and looks in
  the item's repo for a `devloop/<id>-*` branch or worktree, reporting commits
  ahead of the default branch and any uncommitted changes. That's mechanical
  detection only; deciding whether to resume that work or start fresh is
  still your call.
- Group related items when it makes the work better/cheaper — but every item
  still gets its own status updates and thread messages.
- Respect an item's `model` and `effortLevel` hints when spawning sub-work.

## 3. Roles: coordinator, implementer, reviewer

The scheduled run acts as a **coordinator**. It owns the board lifecycle
(claim, read, write-back, status) but should not accumulate a full
implementation's worth of diffs, file reads, and tool output in its own
context — that makes later items in the same run more expensive and the
run itself harder to reason about. Split the actual work into two
sub-agent roles instead:

- **Implementer** — a fresh sub-agent scoped to exactly one item. Give it
  the item's id/title, the thread text relevant to this run (all of it on
  first contact, only the new messages on a reopened item), the repo's
  local path, and the per-item rules from section 4 below (branch/commit
  convention, tests, build). It does the actual coding and reports back a
  short summary: what changed, where, how it verified the work, and
  anything left open.
- **Reviewer** — a second fresh sub-agent, spawned after the implementer
  reports back, pointed at the same repo/branch. Give it the original
  request and the implementer's summary, and ask it to check the diff for
  correctness and scope (does it match what was asked, does it build/test
  cleanly, anything risky or half-done). It does not write code; it reports
  findings.

The coordinator reads only the two summaries — not the raw diff or tool
transcripts — decides whether the reviewer's findings are blocking, and
either sends the implementer sub-agent a follow-up (continuing the same
sub-agent so it keeps full context) or proceeds to write-back.

This split is worth the overhead for `effortLevel: medium`/`high` items.
For `effortLevel: low` or `model: haiku` items, skip the separate reviewer
and just delegate to a single cheap-model sub-agent as before — the
coordination cost isn't worth it for small work. Pass the item's `model`
hint through to the implementer sub-agent when spawning it; the
coordinator's own model is fixed by how the scheduled run itself was
invoked.

Trivial, non-code changes (a one-line doc tweak, a status question) don't
need the full split either — use judgment rather than spawning sub-agents
for their own sake.

## 4. Per item

1. **Claim first** (before any work, so a timeout leaves a truthful state).
   This also logs `item <id> claimed`:
   ```bash
   $PY $CLI items claim <id>
   ```
2. Read the thread. First time on an item, read all of it; on a **reopened**
   item (the thread contains your earlier `agent` messages), read only what's
   new — the user messages after your last reply are the new request, and the
   earlier exchange is background you don't need to redo:
   ```bash
   $PY $CLI items show <id>          # full thread (first contact)
   $PY $CLI items show <id> --new    # only messages since your last reply
   ```
   Messages list attachments as metadata only (name/type/size). Download them
   **only when relevant to the work** — selectively, not wholesale:
   ```bash
   $PY $CLI items fetch <id> --new   # downloads to data/attachments/<id>/
   ```
3. Do the work in the item's repo under `dev/`, using best-practice agentic
   workflows: implement, test, commit — delegated to an implementer (and,
   for medium/high effort, a reviewer) sub-agent per section 3. **Work on
   the `main` branch by default** — commit directly to `main` unless the
   item's thread or the repo itself (a CONTRIBUTING doc, branch-protection,
   an established branch/PR convention) calls for a feature branch. When
   you do branch, open a PR if the repo has a remote workflow that fits.
4. Write results back — always. Include what was done, where (branch/PR
   links), what's left, and anything the user must decide. Attach files or
   screenshots when they help:
   ```bash
   $PY $CLI items post <id> --text "..." --attach path/to/file.png
   ```
5. Set the final status (this also logs `item <id> -> <status>`):
   - `needs-review` — user input or review is required (default for code
     changes),
   - `completed` — done and verified, nothing for the user to decide.
   ```bash
   $PY $CLI items status <id> needs-review
   ```
   Never set `closed` — closing is the user's call.

## 5. Usage budget

Runs share the user's Claude subscription, so treat capacity as finite, but
there is no fixed item-count cap — work through every `open`/`in-progress`
item in the queue, in-progress before open and then by the board's manual
order, re-fetching per section 2 as you go:

- Finish items **one at a time** (post results + set status before starting
  the next) so hitting a limit mid-run never strands more than one item.
- Match spend to the item's hints: for `effortLevel: low` or `model: haiku`
  items, delegate the work to a subagent on that cheaper model and keep your
  own orchestration thin.
- There is currently no way to check remaining subscription usage before or
  during a run — Claude Code doesn't expose the relevant rate-limit headers
  to hooks, scripts, or `--print` mode. Treat this as purely **reactive**:
  if you notice actual rate-limit errors or the run getting cut short, stop
  starting new work immediately, post partial progress to the current
  item's thread as an intentional hand-off, leave it `in-progress`, log it
  right away (section 1), and end the run cleanly. A scheduled slot that
  produced no `run started` line at all was likely blocked before it could
  even begin — the next run's triage will find the stranded item.

## 6. End of run

- Make sure no item you touched is still `in-progress` unless you are
  intentionally handing it to the next run (say so in its thread).
- Call `run end` (with `--note` if the default touched-items summary doesn't
  fit — an idle run, a hand-off, an abnormal stop) so the run's log entry
  always gets written, even if nothing else does.
- Cache/state you want to persist between runs goes in `data/`.
