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

    def git(*args: str, required: bool = True) -> str:
        result = subprocess.run(["git", *args], cwd=repo_dir, text=True,
                                capture_output=True)
        if result.returncode and required:
            raise DispatchError(result.stderr.strip() or "git command failed")
        return result.stdout.strip() if result.returncode == 0 else ""

    branch = git("branch", "--show-current")
    if not branch:
        raise DispatchError("repository has a detached HEAD; refusing unattended dispatch")
    revision = git("rev-parse", "HEAD")
    dirty = git("status", "--porcelain")
    upstream = git(
        "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}",
        required=False,
    )
    unpushed_count = (
        int(git("rev-list", "--count", f"{upstream}..HEAD"))
        if upstream else None
    )
    return {
        "path": str(repo_dir.resolve()),
        "branch": branch,
        "startingRevision": revision,
        "dirty": bool(dirty),
        "status": dirty.splitlines(),
        "upstream": upstream or None,
        "unpushedCommitCount": unpushed_count,
        "usesWorktree": False,
        "gitPolicy": "persistent-repository-checkout",
    }


def checkout_postflight(checkout: dict[str, Any]) -> dict[str, Any]:
    """Collect independent Git evidence after an implementation worker exits."""
    repo_dir = Path(checkout["path"])
    starting_revision = checkout.get("startingRevision")
    if not starting_revision:
        raise DispatchError("checkout is missing its starting revision")

    def git(*args: str, required: bool = True) -> str:
        result = subprocess.run(
            ["git", *args], cwd=repo_dir, text=True, capture_output=True
        )
        if result.returncode and required:
            raise DispatchError(result.stderr.strip() or "git command failed")
        return result.stdout.strip() if result.returncode == 0 else ""

    branch = git("branch", "--show-current")
    revision = git("rev-parse", "HEAD")
    dirty = bool(git("status", "--porcelain"))
    commit_count = int(git("rev-list", "--count", f"{starting_revision}..HEAD"))
    upstream = git(
        "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}",
        required=False,
    )
    unpushed_count = (
        int(git("rev-list", "--count", "@{upstream}..HEAD"))
        if upstream else None
    )
    return {
        "endingBranch": branch,
        "endingRevision": revision,
        "newCommitCount": commit_count,
        "dirty": dirty,
        "upstream": upstream or None,
        "unpushedCommitCount": unpushed_count,
    }


def enforce_git_delivery(
    result: WorkerResult, evidence: dict[str, Any]
) -> WorkerResult:
    """Turn incomplete Git delivery into an explicit human-review result."""
    result.metadata["gitPostflight"] = evidence
    has_repository_work = bool(
        result.files_changed
        or evidence.get("dirty")
        or evidence.get("newCommitCount", 0)
    )
    if not has_repository_work:
        return result

    issues = []
    if evidence.get("endingBranch") != evidence.get("expectedBranch"):
        issues.append(
            f"the checkout moved to branch {evidence.get('endingBranch')!r}"
        )
    if evidence.get("dirty"):
        issues.append("the checkout still has uncommitted changes")
    if result.files_changed and not evidence.get("newCommitCount", 0):
        issues.append("no new commit records the reported file changes")
    if evidence.get("newCommitCount", 0):
        if not evidence.get("upstream"):
            issues.append("the branch has no configured upstream")
        elif evidence.get("unpushedCommitCount"):
            issues.append(
                f"{evidence['unpushedCommitCount']} commit(s) remain unpushed"
            )
    if not issues:
        return result

    return WorkerResult(
        outcome="needs-review",
        summary=f"{result.summary} Git delivery incomplete: {'; '.join(issues)}.",
        files_changed=result.files_changed,
        verification=result.verification,
        provider_reference=result.provider_reference,
        metadata=result.metadata,
    )


def materialize_item_attachments(
    item_id: str, item: dict[str, Any]
) -> list[dict[str, Any]]:
    """Download board attachments through the trusted Firebase boundary."""
    metadata = [
        attachment
        for message in item.get("messages", [])
        for attachment in message.get("attachments", [])
    ]
    if not metadata:
        return []
    paths = items.fetch_attachments(item_id)
    if len(paths) != len(metadata):
        raise DispatchError("downloaded attachment count does not match item metadata")
    return [
        {
            "name": attachment.get("name"),
            "contentType": attachment.get("contentType"),
            "size": attachment.get("size"),
            "path": path,
        }
        for attachment, path in zip(metadata, paths)
    ]


def start(item_id: str, decision: dict[str, Any], adapter: ProviderAdapter, *,
          load_item: Callable[[str], dict[str, Any]] = items.show_item,
          load_repo: Callable[[str], dict[str, Any] | None] = repos.get,
          create_run: Callable[..., str] = runs.create_claimed_assignment,
          post_event: Callable[..., str] = runs.post_routing_event,
          finalize: Callable[..., None] | None = None,
          preflight: Callable[[Path], dict[str, Any]] = checkout_preflight,
          postflight: Callable[
              [dict[str, Any]], dict[str, Any]
          ] = checkout_postflight,
          materialize_attachments: Callable[
              [str, dict[str, Any]], list[dict[str, Any]]
          ] = materialize_item_attachments,
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
    attachments = materialize_attachments(item_id, item)

    try:
        run_id = create_run(
            item_id, decision,
            catalog_version=active_catalog["catalogVersion"],
            router_model="gemma-3-4b-it",
            checkout=checkout,
        )
    except runs.RunConflict as exc:
        raise DispatchError(str(exc)) from exc
    assignment = runs.run_payload(
        decision, catalog_version=active_catalog["catalogVersion"],
        router_model="gemma-3-4b-it",
    )
    post_event(item_id, run_id, assignment)
    task = {
        "itemId": item_id,
        "runId": run_id,
        "title": item.get("title"),
        "request": item.get("messages", []),
        "attachments": attachments,
        "repository": checkout,
        "assignment": decision,
        "gitInstructions": (
            "Continue from the existing persistent repository checkout. Preserve "
            "and build upon its current branch, commits, and working-tree changes "
            "unless the item thread explicitly requires otherwise. Do not create "
            "a worktree. Commit verified repository changes and push when an "
            "upstream is configured."
        ),
    }
    try:
        result = adapter.run(task)
    except Exception as exc:
        result = WorkerResult(outcome="failed", summary=f"Worker failed: {exc}")
    try:
        evidence = postflight(checkout)
        evidence["expectedBranch"] = checkout.get("branch")
        result = enforce_git_delivery(result, evidence)
    except Exception as exc:
        result = WorkerResult(
            outcome="needs-review",
            summary=(
                f"{result.summary} Git delivery could not be verified: "
                f"{type(exc).__name__}: {exc}."
            ),
            files_changed=result.files_changed,
            verification=result.verification,
            provider_reference=result.provider_reference,
            metadata=result.metadata,
        )
    (finalize or _finalize)(item_id, run_id, result)
    return run_id, result


def _finalize(item_id: str, run_id: str, result: WorkerResult) -> None:
    verification = ("\nVerification: " + "; ".join(result.verification)
                    if result.verification else "")
    files = ("\nFiles: " + ", ".join(result.files_changed)
             if result.files_changed else "")
    item_ref = items._items().document(item_id)
    run_ref = item_ref.collection("runs").document(run_id)
    batch = items.fs.db().batch()
    batch.update(run_ref, {
        "state": "finished",
        "result": result.as_dict(),
        "updatedAt": firestore.SERVER_TIMESTAMP,
        "finishedAt": firestore.SERVER_TIMESTAMP,
    })
    if result.outcome == "succeeded":
        status = "completed"
    elif result.outcome == "needs-review":
        status = "needs-review"
    else:
        status = "in-progress"
    batch.update(item_ref, {"status": status, "updatedAt": firestore.SERVER_TIMESTAMP})
    batch.commit()
    items.runlog.log(f"item {item_id} -> {status}")
    try:
        items.post_message(
            item_id,
            f"{result.summary}{files}{verification}",
            author="agent",
        )
    except Exception as exc:
        run_ref.update({
            "writeBackError": f"{type(exc).__name__}: {exc}",
            "updatedAt": firestore.SERVER_TIMESTAMP,
        })
        raise
