"""Action-item operations: list, create, claim, status, post.

Data model (see docs/design.md):
  dev-loop/app/items/{itemId}                 summary doc (small, board-listed)
  dev-loop/app/items/{itemId}/messages/{id}   full thread, one doc per message
"""

from __future__ import annotations

import json
import mimetypes
import uuid
from datetime import datetime, timezone
from pathlib import Path

from firebase_admin import firestore

from . import config, fs


def _items():
    return fs.db().collection(config.ITEMS)


def _summary(doc) -> dict:
    data = doc.to_dict() or {}
    return {
        "id": doc.id,
        "title": data.get("title"),
        "repoId": data.get("repoId"),
        "status": data.get("status"),
        "model": data.get("model"),
        "effortLevel": data.get("effortLevel"),
        "createdAt": _iso(data.get("createdAt")),
        "updatedAt": _iso(data.get("updatedAt")),
        "lastAgentRunAt": _iso(data.get("lastAgentRunAt")),
        "messageCount": data.get("messageCount", 0),
        "archived": bool(data.get("archived", False)),
        "archivedAt": _iso(data.get("archivedAt")),
    }


def _iso(value):
    return value.isoformat() if isinstance(value, datetime) else value


def list_items(statuses: list[str] | None,
               include_archived: bool = False) -> list[dict]:
    query = _items()
    if statuses:
        query = query.where(filter=firestore.firestore.FieldFilter("status", "in", statuses))
    # Archived filtering is applied client-side: existing docs predate the
    # `archived` field, and a Firestore `archived == False` filter would skip
    # those documents entirely.
    items = sorted(
        (
            summary
            for doc in query.stream()
            if (summary := _summary(doc))["archived"] is False or include_archived
        ),
        key=lambda item: item.get("updatedAt") or "",
        reverse=True,
    )
    # Snapshot for the agent / offline inspection.
    config.DATA_DIR.mkdir(exist_ok=True)
    cache = {
        "fetchedAt": datetime.now(timezone.utc).isoformat(),
        "statuses": statuses,
        "includeArchived": include_archived,
        "items": items,
    }
    (config.DATA_DIR / "board-cache.json").write_text(json.dumps(cache, indent=2))
    return items


def create_item(title: str, repo_id: str, text: str | None, model: str | None,
                effort: str | None) -> str:
    ref = _items().document()
    ref.set({
        "title": title,
        "repoId": repo_id,
        "status": "open",
        "model": model,
        "effortLevel": effort,
        "createdAt": firestore.SERVER_TIMESTAMP,
        "updatedAt": firestore.SERVER_TIMESTAMP,
        "lastAgentRunAt": None,
        "messageCount": 0,
        "archived": False,
        "archivedAt": None,
    })
    if text:
        post_message(ref.id, text, author="user")
    return ref.id


def claim_item(item_id: str) -> None:
    """Mark in-progress BEFORE starting work (crash-safe hand-off)."""
    _items().document(item_id).update({
        "status": "in-progress",
        "lastAgentRunAt": firestore.SERVER_TIMESTAMP,
        "updatedAt": firestore.SERVER_TIMESTAMP,
    })


def set_status(item_id: str, status: str) -> None:
    if status not in config.ITEM_STATUSES:
        raise SystemExit(f"invalid status {status!r}; one of {config.ITEM_STATUSES}")
    _items().document(item_id).update({
        "status": status,
        "updatedAt": firestore.SERVER_TIMESTAMP,
    })


def archive_item(item_id: str) -> None:
    """Hide an item from the default board without changing its status."""
    _items().document(item_id).update({
        "archived": True,
        "archivedAt": firestore.SERVER_TIMESTAMP,
        "updatedAt": firestore.SERVER_TIMESTAMP,
    })


def unarchive_item(item_id: str) -> None:
    _items().document(item_id).update({
        "archived": False,
        "archivedAt": None,
        "updatedAt": firestore.SERVER_TIMESTAMP,
    })


def archive_completed() -> list[str]:
    """Archive every non-archived item currently in the `completed` status.

    Returns the ids that were archived (skips ones already archived).
    """
    query = _items().where(
        filter=firestore.firestore.FieldFilter("status", "in", ["completed"])
    )
    archived: list[str] = []
    for doc in query.stream():
        if (doc.to_dict() or {}).get("archived"):
            continue
        archive_item(doc.id)
        archived.append(doc.id)
    return archived


def _upload_attachment(item_id: str, msg_id: str, path: Path) -> dict:
    content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    blob_path = f"{config.ATTACHMENTS_PREFIX}/{item_id}/{msg_id}/{path.name}"
    blob = fs.bucket().blob(blob_path)
    blob.upload_from_filename(str(path), content_type=content_type)
    return {
        "name": path.name,
        "storagePath": blob_path,
        "contentType": content_type,
        "size": path.stat().st_size,
    }


def post_message(item_id: str, text: str, author: str = "agent",
                 attachments: list[str] | None = None) -> str:
    item_ref = _items().document(item_id)
    snapshot = item_ref.get()
    if not snapshot.exists:
        raise SystemExit(f"item {item_id} not found")
    msg_id = uuid.uuid4().hex[:20]
    uploaded = [
        _upload_attachment(item_id, msg_id, Path(p).expanduser())
        for p in attachments or []
    ]
    item_ref.collection("messages").document(msg_id).set({
        "author": author,
        "text": text,
        "attachments": uploaded,
        "createdAt": firestore.SERVER_TIMESTAMP,
    })
    updates = {
        "messageCount": firestore.firestore.Increment(1),
        "updatedAt": firestore.SERVER_TIMESTAMP,
    }
    # A user reply re-queues an item the agent handed back (needs-review /
    # completed) so the next run picks it up; closed stays closed.
    if author == "user" and (snapshot.to_dict() or {}).get("status") in (
        "needs-review",
        "completed",
    ):
        updates["status"] = "open"
    item_ref.update(updates)
    return msg_id


def _thread(doc) -> list[dict]:
    return [
        {"id": m.id, **{k: _iso(v) for k, v in (m.to_dict() or {}).items()}}
        for m in doc.reference.collection("messages").order_by("createdAt").stream()
    ]


def _after_last_agent_reply(messages: list[dict]) -> list[dict]:
    """Messages posted after the agent's last reply (all, if it never replied)."""
    last_agent = max(
        (i for i, m in enumerate(messages) if m.get("author") == "agent"),
        default=-1,
    )
    return messages[last_agent + 1:]


def show_item(item_id: str, new_only: bool = False) -> dict:
    doc = _items().document(item_id).get()
    if not doc.exists:
        raise SystemExit(f"item {item_id} not found")
    messages = _thread(doc)
    result = {**_summary(doc)}
    if new_only:
        new = _after_last_agent_reply(messages)
        result["newMessages"] = new
        result["olderMessageCount"] = len(messages) - len(new)
    else:
        result["messages"] = messages
    return result


def fetch_attachments(item_id: str, new_only: bool = False,
                      out_dir: str | None = None) -> list[str]:
    """Download an item's attachments so the agent can open them on demand.

    Files land in data/attachments/{itemId}/{msgId}/{name} (or --out DIR).
    """
    doc = _items().document(item_id).get()
    if not doc.exists:
        raise SystemExit(f"item {item_id} not found")
    messages = _thread(doc)
    if new_only:
        messages = _after_last_agent_reply(messages)
    base = Path(out_dir).expanduser() if out_dir else (
        config.DATA_DIR / "attachments" / item_id
    )
    bucket = fs.bucket()
    paths: list[str] = []
    for msg in messages:
        for att in msg.get("attachments") or []:
            target = base / msg["id"] / att["name"]
            target.parent.mkdir(parents=True, exist_ok=True)
            bucket.blob(att["storagePath"]).download_to_filename(str(target))
            paths.append(str(target))
    return paths
