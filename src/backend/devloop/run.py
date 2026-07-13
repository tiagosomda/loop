"""Run-level orchestration: bootstrap, deterministic queue, and stale-item
detection, so the scheduled agent doesn't have to re-derive this by hand
every run (see docs/agent-runbook.md).

Lifecycle logging for claims/status changes lives next to those mutations in
items.py, not here, so it can never be skipped by forgetting a separate call.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from . import config, items as items_mod, repos as repos_mod, runlog, schedule

_QUEUE_STATUSES = ("in-progress", "open")


def _order_key(item: dict) -> tuple:
    # in-progress items are a prior run's timed-out claims, not manually
    # ordered work — keep those first, oldest `updatedAt` first, so a stale
    # claim from the oldest run gets resolved before newer ones.
    if item["status"] == "in-progress":
        return (0, item.get("updatedAt") or "")
    # Within `open`, pickup order follows the board's manual `order` field
    # (see docs/design.md / the frontend's drag-to-reorder) rather than
    # `updatedAt` — "what you see on the board is what runs next". This
    # uses the exact same fallback rule as the frontend's own sort
    # (`items_mod.effective_order` / models.dart's `effectiveOrder`): an
    # item that predates manual ordering (never dragged, `order` missing)
    # interleaves by creation time among explicitly-ordered items, instead
    # of being bucketed after all of them — the board and the queue must
    # agree on where an unordered item sits, or "what you see is what runs
    # next" breaks for exactly the items that need it least tested.
    return (1, items_mod.effective_order(item))


def queue() -> list[dict]:
    """Open/in-progress items ordered per the runbook's triage rule.

    Callers should call this again before every claim (not cache a snapshot)
    so a new item or reply created mid-run is picked up.
    """
    raw = items_mod.list_items(list(_QUEUE_STATUSES))
    return sorted(raw, key=_order_key)


def start() -> dict:
    """Bootstrap a run: mark-run (auto-logs "run started"), crawl repos, and
    return the initial queue."""
    schedule.update(mark_run=True)
    crawl_result = repos_mod.crawl()
    return {"repos": crawl_result, "queue": queue()}


def next_item() -> dict | None:
    """The single next item to work, freshly queried."""
    q = queue()
    return q[0] if q else None


def _touched_since_last_start() -> list[str]:
    """Item ids with a claim/status log line since the most recent
    "run started", used to compose a run-finished summary without the
    caller needing to track state across separate CLI invocations."""
    lines = runlog.tail(2000)
    start_at = 0
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].endswith("run started"):
            start_at = i
            break
    touched: list[str] = []
    for line in lines[start_at:]:
        if " item " not in line:
            continue
        rest = line.split(" item ", 1)[1]
        item_id = rest.split(" ", 1)[0]
        if item_id and item_id not in touched:
            touched.append(item_id)
    return touched


def end(note: str | None = None) -> str:
    """Log a "run finished" line. Without --note, summarizes item ids touched
    (claimed or status-changed) since the last "run started" line."""
    if note:
        summary = note
    else:
        touched = _touched_since_last_start()
        summary = (f"{len(touched)} item(s) touched: {', '.join(touched)}"
                   if touched else "no items touched")
    return runlog.log(f"run finished: {summary}")


def _git(repo_dir: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=repo_dir, capture_output=True, text=True,
    )
    return result.stdout.strip()


def check_stale(item_id: str) -> dict:
    """Look for local evidence of a previous run's WIP on an in-progress item:
    a `devloop/<item_id>-*` branch, whether it has commits ahead of the
    default branch, and whether an associated worktree has uncommitted
    changes. Purely mechanical detection — deciding whether to resume or
    restart is still a judgment call for the agent."""
    item = items_mod.show_item(item_id)
    repo_id = item.get("repoId")
    repo = repos_mod.get(repo_id) if repo_id else None
    if not repo:
        return {"itemId": item_id, "repoId": repo_id, "found": False,
                "note": f"repo {repo_id!r} not found in registry"}

    repo_dir = (config.DEV_ROOT / repo["path"]).resolve()
    if not repo_dir.is_dir():
        return {"itemId": item_id, "repoId": repo_id, "found": False,
                "note": f"repo path {repo_dir} does not exist on disk"}

    branch_pattern = f"devloop/{item_id}-*"
    # `git branch --list` prefixes the current branch with "* " and a branch
    # checked out in another worktree with "+ " — strip either.
    branches = [
        b.strip().lstrip("*+ ").strip()
        for b in _git(repo_dir, "branch", "--list", branch_pattern).splitlines()
        if b.strip()
    ]
    if not branches:
        return {"itemId": item_id, "repoId": repo_id, "found": False,
                "note": "no devloop/<id>-* branch found"}

    branch = branches[0]
    default_branch = "main" if _git(repo_dir, "rev-parse", "--verify", "main") else "master"
    ahead = _git(repo_dir, "log", "--oneline", f"{default_branch}..{branch}")
    commits_ahead = len(ahead.splitlines()) if ahead else 0

    worktrees = _git(repo_dir, "worktree", "list", "--porcelain")
    worktree_path = None
    for block in worktrees.split("\n\n"):
        if f"branch refs/heads/{branch}" in block:
            for line in block.splitlines():
                if line.startswith("worktree "):
                    worktree_path = line.split(" ", 1)[1]
    uncommitted = None
    if worktree_path and Path(worktree_path).is_dir():
        status = _git(Path(worktree_path), "status", "--porcelain")
        uncommitted = bool(status)

    return {
        "itemId": item_id,
        "repoId": repo_id,
        "found": True,
        "branch": branch,
        "commitsAheadOfDefault": commits_ahead,
        "worktreePath": worktree_path,
        "hasUncommittedChanges": uncommitted,
    }
