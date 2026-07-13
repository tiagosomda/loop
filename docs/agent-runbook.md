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
$PY $CLI schedule update --mark-run    # also logs "run started" to the run log
$PY $CLI repos crawl
$PY $CLI items list --status open,in-progress
```

**Run log** (`data/agent-runs.log`): every run must leave a trace. The
mark-run above logs the start automatically; you log the rest:

```bash
$PY $CLI runlog add "item <id> -> needs-review (<one-line outcome>)"
$PY $CLI runlog add "run finished: 2 items worked, 1 left open"
$PY $CLI runlog tail          # recent history when debugging
```

Log an item line after finishing each item, a `run finished` line at the end
(even when there was nothing to do — "run finished: no open items"), and a
line for anything abnormal (rate limit, hand-off, failure). A scheduled slot
with no "run started" line means the run never executed at all (e.g. the
model was rate-limited before it could act); a "run started" with no
"run finished" means it died mid-run — check for stale in-progress items.

## 2. Triage

- **Refresh before every pick, not just at the start of the run.** The list
  from step 1 is a snapshot; the user can add a new item or reply to an
  open thread while the run is in progress. Before claiming each item —
  including the first — re-run `items list --status open,in-progress` and
  fold in anything new using the same ordering rule below, rather than
  working through a stale in-memory list.
- **Work `in-progress` items before `open` ones.** An in-progress item was
  claimed by a previous run that likely timed out mid-work — finishing it
  first avoids stranding partial work and keeps the board truthful. Only once
  the in-progress items are handled do you start on `open` items. Within each
  of those two groups, go oldest `updatedAt` first.
- For each `in-progress` item: it was claimed by a previous run that likely
  timed out. Check `lastAgentRunAt`; look in the item's repo (under `dev/`,
  see the repo's `path` in the repos registry) for a work-in-progress branch,
  uncommitted changes, or an open PR related to the item. Resume that work if
  it exists; otherwise treat the item as fresh.
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

1. **Claim first** (before any work, so a timeout leaves a truthful state):
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
5. Set the final status:
   - `needs-review` — user input or review is required (default for code
     changes),
   - `completed` — done and verified, nothing for the user to decide.
   ```bash
   $PY $CLI items status <id> needs-review
   ```
   Never set `closed` — closing is the user's call.

## 5. Usage budget

Runs share the user's Claude subscription, so treat capacity as finite:

- **Work at most 2 items per run**, in-progress items before open ones and
  oldest `updatedAt` first within each group. Anything left simply stays for
  the next run — that's normal, not a failure.
- Finish items **one at a time** (post results + set status before starting
  the next) so hitting a limit mid-run never strands more than one item.
- Match spend to the item's hints: for `effortLevel: low` or `model: haiku`
  items, delegate the work to a subagent on that cheaper model and keep your
  own orchestration thin. The coordinator/implementer/reviewer split (section
  3) costs more sub-agent calls per item than doing it all inline — that
  overhead buys a smaller, more reliable coordinator context, not a smaller
  total spend, so still cap it at two items per run.
- If you notice rate-limit errors or the run getting cut short, stop starting
  new work: post partial progress to the current item's thread, say it's an
  intentional hand-off, leave it `in-progress`, and end the run cleanly.

## 6. End of run

- Make sure no item you touched is still `in-progress` unless you are
  intentionally handing it to the next run (say so in its thread).
- Cache/state you want to persist between runs goes in `data/`.
