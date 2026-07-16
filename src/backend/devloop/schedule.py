"""Publish the agent's wake-up schedule so the frontend can display it."""

from __future__ import annotations

from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from firebase_admin import firestore

from . import config, fs, runlog


def _upcoming(times: tuple[str, ...], now: datetime | None, count: int) -> list[datetime]:
    """Return the next launchd wall-clock slots as timezone-aware UTC values."""
    if count < 1:
        return []
    zone = ZoneInfo(config.SCHEDULE_TIMEZONE)
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    local_now = current.astimezone(zone)
    parsed_times = tuple(
        time(hour=int(value[:2]), minute=int(value[3:]))
        for value in times
    )
    runs: list[datetime] = []
    day: date = local_now.date()
    while len(runs) < count:
        for scheduled_time in parsed_times:
            candidate = datetime.combine(day, scheduled_time, tzinfo=zone)
            if candidate > local_now:
                runs.append(candidate.astimezone(timezone.utc))
                if len(runs) == count:
                    break
        day += timedelta(days=1)
    return runs


def upcoming_runs(now: datetime | None = None, count: int = 12) -> list[datetime]:
    """Return upcoming normal dev-loop sessions."""
    return _upcoming(config.SCHEDULE_TIMES, now, count)


def upcoming_sessions(now: datetime | None = None, count: int = 16) -> list[dict]:
    """Return all session types ordered as concrete UTC instants."""
    sessions = [
        {"kind": "dev-loop", "startsAt": value}
        for value in _upcoming(config.SCHEDULE_TIMES, now, count)
    ] + [
        {"kind": "self-healing", "startsAt": value}
        for value in _upcoming(config.SELF_HEALING_SCHEDULE_TIMES, now, count)
    ]
    return sorted(sessions, key=lambda value: value["startsAt"])[:count]


def update(mark_run: bool = False) -> dict:
    next_runs = upcoming_runs()
    next_sessions = upcoming_sessions()
    payload = {
        "times": list(config.SCHEDULE_TIMES),
        "sessions": [
            *[{"kind": "dev-loop", "time": value} for value in config.SCHEDULE_TIMES],
            *[{"kind": "self-healing", "time": value}
              for value in config.SELF_HEALING_SCHEDULE_TIMES],
        ],
        "timezone": config.SCHEDULE_TIMEZONE,
        "nextRunsAt": next_runs,
        "nextSessions": next_sessions,
        "scheduler": "launchd",
        "updatedAt": firestore.SERVER_TIMESTAMP,
    }
    if mark_run:
        payload["lastRunAt"] = firestore.SERVER_TIMESTAMP
        runlog.log("run started")
    fs.db().document(config.SCHEDULE_DOC).set(payload, merge=True)
    return {
        "times": payload["times"],
        "timezone": payload["timezone"],
        "nextRunsAt": [run.isoformat() for run in next_runs],
        "nextSessions": [
            {**session, "startsAt": session["startsAt"].isoformat()}
            for session in next_sessions
        ],
        "markedRun": mark_run,
    }


def mark_self_healing(outcome: str | None = None, summary: str | None = None) -> None:
    """Publish self-healing lifecycle without changing normal-run health."""
    payload = {
        "lastSelfHealingAt": firestore.SERVER_TIMESTAMP,
        "updatedAt": firestore.SERVER_TIMESTAMP,
    }
    if outcome is not None:
        payload.update({
            "lastSelfHealingOutcome": outcome,
            "lastSelfHealingSummary": summary or "",
            "lastSelfHealingFinishedAt": firestore.SERVER_TIMESTAMP,
        })
    fs.db().document(config.SCHEDULE_DOC).set(payload, merge=True)


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
