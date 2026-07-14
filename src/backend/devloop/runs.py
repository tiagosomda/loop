"""Per-attempt run records and idempotent structured routing events."""

from __future__ import annotations

import uuid
from typing import Any

from firebase_admin import firestore

from . import config, fs, runlog


class RunConflict(RuntimeError):
    pass


def run_payload(decision: dict[str, Any], *, catalog_version: str,
                router_model: str) -> dict[str, Any]:
    return {
        "state": "assigned",
        "targetId": decision["targetId"],
        "provider": decision["provider"],
        "model": decision["model"],
        "effort": decision["effort"],
        "reasonCodes": decision["reasonCodes"],
        "confidence": decision["confidence"],
        "catalogVersion": catalog_version,
        "routerModel": router_model,
        "createdAt": firestore.SERVER_TIMESTAMP,
        "updatedAt": firestore.SERVER_TIMESTAMP,
    }


def routing_event_payload(run_id: str, assignment: dict[str, Any],
                          *, state: str = "assigned") -> dict[str, Any]:
    return {
        "kind": "routing",
        "author": "system",
        "text": "",
        "attachments": [],
        "runId": run_id,
        "state": state,
        "targetId": assignment["targetId"],
        "provider": assignment["provider"],
        "model": assignment["model"],
        "effort": assignment["effort"],
        "reasonCodes": assignment.get("reasonCodes", []),
        "catalogVersion": assignment["catalogVersion"],
        "createdAt": firestore.SERVER_TIMESTAMP,
    }


def routing_event_id(run_id: str, state: str) -> str:
    """Stable identity used by retries of the same run transition."""
    return f"routing-{run_id}-{state}"


def create_assignment(item_id: str, decision: dict[str, Any], *,
                      catalog_version: str, router_model: str,
                      post_event: bool = True) -> str:
    """Record an assignment before dispatch; item request fields stay untouched."""
    run_id = uuid.uuid4().hex
    item_ref = fs.db().collection(config.ITEMS).document(item_id)
    run_ref = item_ref.collection("runs").document(run_id)
    payload = run_payload(decision, catalog_version=catalog_version,
                          router_model=router_model)
    batch = fs.db().batch()
    batch.set(run_ref, payload)
    batch.update(item_ref, {
        "lastRunId": run_id,
        "updatedAt": firestore.SERVER_TIMESTAMP,
    })
    batch.commit()
    if post_event:
        post_routing_event(item_ref, run_id, payload)
    return run_id


def create_claimed_assignment(item_id: str, decision: dict[str, Any], *,
                              catalog_version: str, router_model: str,
                              checkout: dict[str, Any]) -> str:
    """Atomically recheck eligibility, record the run, and claim the item."""
    run_id = uuid.uuid4().hex
    item_ref = fs.db().collection(config.ITEMS).document(item_id)
    run_ref = item_ref.collection("runs").document(run_id)
    payload = run_payload(decision, catalog_version=catalog_version,
                          router_model=router_model)
    payload.update({"state": "running", "checkout": checkout,
                    "startedAt": firestore.SERVER_TIMESTAMP})
    transaction = fs.db().transaction()

    @firestore.transactional
    def assign_and_claim(tx):
        snapshot = item_ref.get(transaction=tx)
        if not snapshot.exists or (snapshot.to_dict() or {}).get("status") != "open":
            status = (snapshot.to_dict() or {}).get("status") if snapshot.exists else "missing"
            raise RunConflict(f"item is no longer eligible: {status}")
        tx.set(run_ref, payload)
        tx.update(item_ref, {
            "status": "in-progress",
            "lastAgentRunAt": firestore.SERVER_TIMESTAMP,
            "lastRunId": run_id,
            "updatedAt": firestore.SERVER_TIMESTAMP,
        })

    assign_and_claim(transaction)
    runlog.log(f"item {item_id} claimed for run {run_id}")
    return run_id


def post_routing_event(item_or_ref, run_id: str, assignment: dict[str, Any],
                       *, state: str = "assigned") -> str:
    """Create one deterministic event document; retries cannot duplicate it."""
    item_ref = (fs.db().collection(config.ITEMS).document(item_or_ref)
                if isinstance(item_or_ref, str) else item_or_ref)
    event_id = routing_event_id(run_id, state)
    event_ref = item_ref.collection("messages").document(event_id)
    transaction = fs.db().transaction()

    @firestore.transactional
    def create_once(tx):
        if event_ref.get(transaction=tx).exists:
            return False
        tx.set(event_ref, routing_event_payload(run_id, assignment, state=state))
        tx.update(item_ref, {
            "messageCount": firestore.firestore.Increment(1),
            "updatedAt": firestore.SERVER_TIMESTAMP,
        })
        return True

    create_once(transaction)
    return event_id
