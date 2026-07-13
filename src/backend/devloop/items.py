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
    }


def _iso(value):
    return value.isoformat() if isinstance(value, datetime) else value


def list_items(statuses: list[str] | None) -> list[dict]:
    query = _items()
    if statuses:
        query = query.where(filter=firestore.firestore.FieldFilter("status", "in", statuses))
    items = sorted(
        (_summary(doc) for doc in query.stream()),
        key=lambda item: item.get("updatedAt") or "",
        reverse=True,
    )
    # Snapshot for the agent / offline inspection.
    config.DATA_DIR.mkdir(exist_ok=True)
    cache = {
        "fetchedAt": datetime.now(timezone.utc).isoformat(),
        "statuses": statuses,
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
    if not item_ref.get().exists:
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
    item_ref.update({
        "messageCount": firestore.firestore.Increment(1),
        "updatedAt": firestore.SERVER_TIMESTAMP,
    })
    return msg_id


def show_item(item_id: str) -> dict:
    doc = _items().document(item_id).get()
    if not doc.exists:
        raise SystemExit(f"item {item_id} not found")
    messages = [
        {"id": m.id, **{k: _iso(v) for k, v in (m.to_dict() or {}).items()}}
        for m in doc.reference.collection("messages").order_by("createdAt").stream()
    ]
    return {**_summary(doc), "messages": messages}
