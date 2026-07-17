"""Daily diagnostic session for errors produced by scheduled dev-loop runs."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from . import config, dispatcher, items, router, runlog, schedule, targets
from .adapters import for_target
from .autonomous import single_instance

STATE_FILE = config.DATA_DIR / "agent-runs" / "self-healing-state.json"
ERROR_LOG = config.DATA_DIR / "orchestrator.error.log"
SELF_ERROR_LOG = config.DATA_DIR / "self-healing.error.log"


def _read_new(path: Path, offset: int) -> tuple[str, int]:
    if not path.is_file():
        return "", 0
    size = path.stat().st_size
    start = offset if 0 <= offset <= size else 0
    with path.open("r", errors="replace") as handle:
        handle.seek(start)
        return handle.read(), size


def collect_evidence(state: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    """Collect bounded, newly appended failure evidence from both run logs."""
    run_text, run_offset = _read_new(runlog.LOG_FILE, int(state.get("runLogOffset", 0)))
    error_text, error_offset = _read_new(ERROR_LOG, int(state.get("errorLogOffset", 0)))
    self_error_text, self_error_offset = _read_new(
        SELF_ERROR_LOG, int(state.get("selfErrorLogOffset", 0))
    )
    failed_runs = [
        line for line in run_text.splitlines()
        if "run finished: failed:" in line or "status publish failed" in line
    ]
    error_lines = (error_text + "\n" + self_error_text).splitlines()
    traceback_starts = [i for i, line in enumerate(error_lines) if line == "Traceback (most recent call last):"]
    traceback_blocks = [
        "\n".join(error_lines[index:index + 18]) for index in traceback_starts
    ]
    evidence = "\n\n".join([
        *(f"Run log: {line}" for line in failed_runs[-20:]),
        *(f"Error log:\n{block}" for block in traceback_blocks[-10:]),
    ])[-24000:]
    return evidence, {
        "runLogOffset": run_offset,
        "errorLogOffset": error_offset,
        "selfErrorLogOffset": self_error_offset,
    }


def _save_state(state: dict[str, Any]) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary = STATE_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2))
    temporary.replace(STATE_FILE)


def _decision(item_id: str) -> tuple[dict[str, Any], dict[str, Any]]:
    context = router.build_context(item_id)
    catalog = targets.load()
    try:
        decision = router.decide(context)
    except router.RoutingError as exc:
        decision = router.fallback_decision(context, catalog)
        if decision is None:
            raise dispatcher.DispatchError(str(exc)) from exc
    return decision, catalog


def execute() -> dict[str, Any]:
    """Inspect new failures, create one diagnostic item, and attempt repair."""
    with single_instance():
        schedule.mark_self_healing()
        runlog.log("self-healing started")
        state = json.loads(STATE_FILE.read_text()) if STATE_FILE.is_file() else {}
        evidence, new_state = collect_evidence(state)
        if not evidence:
            _save_state(new_state)
            schedule.mark_self_healing("finished", "no new errors found")
            runlog.log("self-healing finished: no new errors found")
            return {"created": False, "outcome": "no-errors"}

        title = "Self-healing: scheduled run errors"
        request = (
            "The daily self-healing session found the scheduled-run errors below. "
            "Diagnose them in the dev-loop repository. If the cause is clear and "
            "safe to correct, implement and verify the fix. If it is not clear, "
            "do not guess: document the likely cause and the direction needed. "
            "Preserve the current repository branch and working tree.\n\n"
            f"Observed evidence:\n{evidence}"
        )
        # Route the diagnostic item automatically; pinning a provider here breaks
        # self-healing whenever that provider is disabled in the catalog.
        item_id = items.create_item(title, config.SELF_HEALING_REPO_ID, request,
                                    None, "high", None)
        # Once the evidence has a durable board item, advance the cursors so a
        # worker crash cannot create a duplicate diagnostic item tomorrow.
        _save_state(new_state)
        outcome = "needs-review"
        summary = "Diagnostic item created; automatic repair was not started."
        try:
            decision, catalog = _decision(item_id)
            selected = next(
                target for target in catalog["targets"]
                if target["targetId"] == decision["targetId"] and target["enabled"]
            )
            _, result = dispatcher.start(
                item_id, decision, for_target(selected), catalog=catalog
            )
            summary = result.summary
        except Exception as exc:
            summary = f"Automatic diagnosis/repair stopped: {type(exc).__name__}: {exc}"
            items.post_message(item_id, summary, author="agent")
        finally:
            items.set_status(item_id, "needs-review")

        schedule.mark_self_healing(outcome, summary)
        runlog.log(f"self-healing finished: item {item_id} -> needs-review")
        return {"created": True, "itemId": item_id, "outcome": outcome,
                "summary": summary}
