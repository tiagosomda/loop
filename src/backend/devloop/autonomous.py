"""Single-process autonomous queue orchestration for local scheduling."""

from __future__ import annotations

import fcntl
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable

from . import config, dispatcher, items, router, run, targets
from .adapters import for_target


class AlreadyRunning(RuntimeError):
    pass


@contextmanager
def single_instance(path: Path | None = None):
    lock_path = path or (config.DATA_DIR / "agent-runs" / "orchestrator.lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    handle = lock_path.open("a+")
    try:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise AlreadyRunning("an autonomous run is already active") from exc
        yield
    finally:
        handle.close()


def pause_for_recovery(item: dict[str, Any]) -> dict[str, Any]:
    """Surface stale evidence and unblock later open items without rerouting."""
    evidence = run.check_stale(item["id"])
    items.pause_for_review(
        item["id"],
        "Autonomous recovery paused this prior run for review. No new provider "
        "was selected and existing repository work was left untouched.\n\n"
        f"Recovery evidence: {evidence}",
    )
    return {"itemId": item["id"], "outcome": "needs-human-recovery"}


def pause_for_routing(item: dict[str, Any], reason: str) -> dict[str, Any]:
    """Surface a safe router abstention without retrying it every schedule."""
    items.pause_for_review(
        item["id"],
        "Automatic routing paused this item for review. No worker was launched "
        "and the repository was not changed.\n\n"
        f"Reason: {reason}",
    )
    return {"itemId": item["id"], "outcome": "needs-human-routing"}


def execute(*, start_run: Callable[[], Any] = run.start,
            next_item: Callable[[], dict[str, Any] | None] = run.next_item,
            end_run: Callable[..., str] = run.end,
            build_context: Callable[[str], dict[str, Any]] = router.build_context,
            choose: Callable[[dict[str, Any]], dict[str, Any]] = router.decide,
            choose_fallback: Callable[
                [dict[str, Any], dict[str, Any]], dict[str, Any] | None
            ] = router.fallback_decision,
            dispatch: Callable[..., Any] = dispatcher.start,
            load_catalog: Callable[[], dict[str, Any]] = targets.load,
            adapter_factory: Callable[[dict[str, Any]], Any] = for_target,
            recover: Callable[[dict[str, Any]], dict[str, Any]] = pause_for_recovery,
            pause_routing: Callable[[dict[str, Any], str], dict[str, Any]] = pause_for_routing,
            lock: Callable[[], Any] = single_instance,
            max_items: int | None = None) -> dict[str, Any]:
    processed: list[dict[str, Any]] = []
    with lock():
        started = False
        failure: Exception | None = None
        try:
            # Once the local invocation owns the lock it must leave an end
            # trace even when bootstrap fails partway through.
            started = True
            start_run()
            while max_items is None or len(processed) < max_items:
                item = next_item()
                if item is None:
                    break
                if item.get("status") == "in-progress":
                    processed.append(recover(item))
                    continue
                context = build_context(item["id"])
                catalog = None
                try:
                    decision = choose(context)
                except router.RoutingError as exc:
                    reason = str(exc)
                    if not reason.startswith("needs-human-routing:"):
                        raise
                    catalog = load_catalog()
                    decision = choose_fallback(context, catalog)
                    if decision is None:
                        processed.append(pause_routing(item, reason))
                        continue
                catalog = catalog or load_catalog()
                selected = next(
                    (target for target in catalog["targets"]
                     if target["targetId"] == decision["targetId"]),
                    None,
                )
                if selected is None or not selected["enabled"]:
                    raise RuntimeError("router selected a missing or disabled target")
                adapter = adapter_factory(selected)
                run_id, result = dispatch(
                    item["id"], decision, adapter, catalog=catalog
                )
                processed.append({
                    "itemId": item["id"], "runId": run_id,
                    "outcome": result.outcome,
                })
        except Exception as exc:
            failure = exc
            raise
        finally:
            if started:
                if failure is None:
                    end_run()
                else:
                    end_run(
                        note=f"failed: {type(failure).__name__}: {failure}",
                        outcome="failed",
                    )
    return {"processed": processed, "count": len(processed)}
