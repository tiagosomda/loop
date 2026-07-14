"""Publish the agent's wake-up schedule so the frontend can display it."""

from __future__ import annotations

from firebase_admin import firestore

from . import config, fs, runlog


def update(mark_run: bool = False) -> dict:
    payload = {
        "times": list(config.SCHEDULE_TIMES),
        "timezone": "local",
        "scheduler": "launchd",
        "updatedAt": firestore.SERVER_TIMESTAMP,
    }
    if mark_run:
        payload["lastRunAt"] = firestore.SERVER_TIMESTAMP
        runlog.log("run started")
    fs.db().document(config.SCHEDULE_DOC).set(payload, merge=True)
    return {"times": payload["times"], "markedRun": mark_run}


def finish(outcome: str, summary: str) -> None:
    """Publish a safe operational snapshot after every locally-started run."""
    from . import targets

    catalog = targets.safe_projection(include_availability=True)
    router = next(
        (target for target in catalog["targets"] if target["role"] == "router"),
        None,
    )
    providers = [
        {
            "targetId": target["targetId"],
            "adapter": target["adapter"],
            "enabled": target["enabled"],
            "availability": target["availability"],
        }
        for target in catalog["targets"] if target["role"] == "worker"
    ]
    fs.db().document(config.SCHEDULE_DOC).set({
        "lastFinishedAt": firestore.SERVER_TIMESTAMP,
        "lastOutcome": outcome,
        "lastSummary": summary,
        "routerHealth": router["availability"] if router else {
            "available": False, "reason": "not-configured",
        },
        "providers": providers,
        "updatedAt": firestore.SERVER_TIMESTAMP,
    }, merge=True)
