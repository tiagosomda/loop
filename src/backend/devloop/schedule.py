"""Publish the agent's wake-up schedule so the frontend can display it."""

from __future__ import annotations

from firebase_admin import firestore

from . import config, fs, runlog


def update(mark_run: bool = False) -> dict:
    payload = {
        "times": list(config.SCHEDULE_TIMES),
        "timezone": "local",
        "updatedAt": firestore.SERVER_TIMESTAMP,
    }
    if mark_run:
        payload["lastRunAt"] = firestore.SERVER_TIMESTAMP
        runlog.log("run started")
    fs.db().document(config.SCHEDULE_DOC).set(payload, merge=True)
    return {"times": payload["times"], "markedRun": mark_run}
