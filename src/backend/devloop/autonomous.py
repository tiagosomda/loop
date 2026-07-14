"""Single-process autonomous queue orchestration for local scheduling."""

from __future__ import annotations

import fcntl
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable

from . import config, dispatcher, router, run, targets
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


def execute(*, start_run: Callable[[], Any] = run.start,
            next_item: Callable[[], dict[str, Any] | None] = run.next_item,
            end_run: Callable[..., str] = run.end,
            build_context: Callable[[str], dict[str, Any]] = router.build_context,
            choose: Callable[[dict[str, Any]], dict[str, Any]] = router.decide,
            dispatch: Callable[..., Any] = dispatcher.start,
            load_catalog: Callable[[], dict[str, Any]] = targets.load,
            adapter_factory: Callable[[dict[str, Any]], Any] = for_target,
            lock: Callable[[], Any] = single_instance,
            max_items: int | None = None) -> dict[str, Any]:
    processed: list[dict[str, Any]] = []
    with lock():
        started = False
        try:
            start_run()
            started = True
            while max_items is None or len(processed) < max_items:
                item = next_item()
                if item is None:
                    break
                if item.get("status") == "in-progress":
                    raise RuntimeError(
                        f"item {item['id']} requires explicit stale-run recovery"
                    )
                context = build_context(item["id"])
                decision = choose(context)
                catalog = load_catalog()
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
        finally:
            if started:
                end_run()
    return {"processed": processed, "count": len(processed)}
