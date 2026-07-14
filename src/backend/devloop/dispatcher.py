"""Validated, deterministic dispatch lifecycle around trusted adapters."""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any, Callable

from firebase_admin import firestore

from . import config, items, repos, router, runs, targets
from .adapters.base import ProviderAdapter, WorkerResult


class DispatchError(RuntimeError):
    pass


def checkout_preflight(repo_dir: Path) -> dict[str, Any]:
    if not repo_dir.is_dir():
        raise DispatchError(f"repository path does not exist: {repo_dir}")

    def git(*args: str) -> str:
        result = subprocess.run(["git", *args], cwd=repo_dir, text=True,
                                capture_output=True)
        if result.returncode:
            raise DispatchError(result.stderr.strip() or "git command failed")
        return result.stdout.strip()

    branch = git("branch", "--show-current")
    dirty = git("status", "--porcelain")
    if dirty:
        raise DispatchError("repository has uncommitted changes; refusing unattended dispatch")
    return {
        "path": str(repo_dir.resolve()),
        "branch": branch,
        "usesWorktree": False,
        "gitPolicy": "existing-checkout-main-by-default",
    }


def start(item_id: str, decision: dict[str, Any], adapter: ProviderAdapter, *,
          load_item: Callable[[str], dict[str, Any]] = items.show_item,
          load_repo: Callable[[str], dict[str, Any] | None] = repos.get,
          create_run: Callable[..., str] = runs.create_assignment,
          claim: Callable[[str], None] = items.claim_item,
          post_event: Callable[..., str] = runs.post_routing_event,
          finalize: Callable[..., None] | None = None,
          preflight: Callable[[Path], dict[str, Any]] = checkout_preflight,
          catalog: dict[str, Any] | None = None) -> tuple[str, WorkerResult]:
    item = load_item(item_id)
    if item.get("status") != "open":
        raise DispatchError(f"item is no longer eligible: {item.get('status')}")

    active_catalog = catalog or targets.load()
    allowed = []
    selected_target = None
    for target in active_catalog["targets"]:
        if target["role"] != "worker" or not target["enabled"]:
            continue
        public = {key: value for key, value in target.items()
                  if key not in {"executable", "endpoint"}}
        allowed.append(public)
        if target["targetId"] == decision.get("targetId"):
            selected_target = target
    validation_context = {
        "item": {"id": item_id},
        "requested": {
            "provider": item.get("requestedProvider"),
            "model": item.get("requestedModel", item.get("model")),
            "effort": item.get("requestedEffort", item.get("effortLevel")),
        },
        "allowedTargets": allowed,
    }
    router.validate_decision(validation_context, decision)
    if selected_target is None:
        raise DispatchError("selected target is not enabled")
    availability = targets.probe(selected_target)
    if not availability["available"]:
        raise DispatchError(f"selected target became unavailable: {availability['reason']}")

    repo = load_repo(item.get("repoId"))
    if not repo:
        raise DispatchError(f"repository {item.get('repoId')!r} not found")
    checkout = preflight((config.DEV_ROOT / repo["path"]).resolve())

    run_id = create_run(
        item_id, decision,
        catalog_version=active_catalog["catalogVersion"],
        router_model="gemma-3-4b-it",
        post_event=False,
    )
    claim(item_id)
    assignment = runs.run_payload(
        decision, catalog_version=active_catalog["catalogVersion"],
        router_model="gemma-3-4b-it",
    )
    post_event(item_id, run_id, assignment)
    task = {
        "itemId": item_id,
        "title": item.get("title"),
        "request": item.get("messages", []),
        "repository": checkout,
        "assignment": decision,
        "gitInstructions": (
            "Use the existing checkout and main branch by default. Do not create "
            "a worktree or branch unless repository or item instructions require it."
        ),
    }
    try:
        result = adapter.run(task)
    except Exception as exc:
        result = WorkerResult(outcome="failed", summary=f"Worker failed: {exc}")
    (finalize or _finalize)(item_id, run_id, result)
    return run_id, result


def _finalize(item_id: str, run_id: str, result: WorkerResult) -> None:
    verification = ("\nVerification: " + "; ".join(result.verification)
                    if result.verification else "")
    files = ("\nFiles: " + ", ".join(result.files_changed)
             if result.files_changed else "")
    items.post_message(
        item_id,
        f"{result.summary}{files}{verification}",
        author="agent",
    )
    item_ref = items._items().document(item_id)
    run_ref = item_ref.collection("runs").document(run_id)
    batch = items.fs.db().batch()
    batch.update(run_ref, {
        "state": "finished",
        "result": result.as_dict(),
        "updatedAt": firestore.SERVER_TIMESTAMP,
        "finishedAt": firestore.SERVER_TIMESTAMP,
    })
    status = "needs-review" if result.outcome in {"succeeded", "needs-review"} else "in-progress"
    batch.update(item_ref, {"status": status, "updatedAt": firestore.SERVER_TIMESTAMP})
    batch.commit()
