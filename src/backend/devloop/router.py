"""Sanitized routing context and schema-constrained local llama.cpp decisions."""

from __future__ import annotations

import copy
import json
import re
from datetime import datetime, timezone
from typing import Any

import requests

from . import config, items, repos, targets

DECISION_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": [
        "schemaVersion", "itemId", "targetId", "provider", "model",
        "effort", "reasonCodes", "confidence",
    ],
    "properties": {
        "schemaVersion": {"const": 1},
        "itemId": {"type": "string", "minLength": 1},
        "targetId": {"type": "string", "minLength": 1},
        "provider": {"type": "string", "minLength": 1},
        "model": {"type": "string", "minLength": 1},
        "effort": {"enum": ["low", "medium", "high", "max"]},
        "reasonCodes": {
            "type": "array", "maxItems": 5,
            "items": {"type": "string", "pattern": "^[a-z0-9-]+$"},
        },
        "confidence": {"enum": ["low", "medium", "high"]},
    },
}


class RoutingError(RuntimeError):
    pass


def build_context(item_id: str) -> dict[str, Any]:
    item = items.show_item(item_id)
    repo_id = item.get("repoId")
    repo = repos.get(repo_id) if repo_id else None
    requested = {
        "provider": item.get("requestedProvider"),
        "model": item.get("requestedModel", item.get("model")),
        "effort": item.get("requestedEffort", item.get("effortLevel")),
    }
    requires_attachment_support = bool(_attachment_metadata(item))
    workers = [
        target for target in targets.enabled_available_workers()
        if (_matches_request(target, requested) and
            (not requires_attachment_support or target.get("supportsImages")))
    ]
    return {
        "schemaVersion": 1,
        "item": {
            "id": item_id,
            "title": item.get("title"),
            "status": item.get("status"),
            "request": _request_text(item),
            "attachmentMetadata": _attachment_metadata(item),
        },
        "repository": {
            "id": repo_id,
            "name": repo.get("name") if repo else None,
            "path": repo.get("path") if repo else None,
            "host": repo.get("host") if repo else None,
        },
        "requested": requested,
        "allowedTargets": workers,
    }


def _matches_request(target: dict[str, Any], requested: dict[str, Any]) -> bool:
    return (
        (requested.get("provider") in (None, target["adapter"])) and
        (requested.get("model") is None or requested["model"] in target["models"]) and
        (requested.get("effort") is None or
         requested["effort"] in target["effortLevels"])
    )


def _request_text(item: dict[str, Any]) -> str:
    messages = item.get("messages") or []
    user_text = [str(message.get("text", "")) for message in messages
                 if message.get("author") == "user" and message.get("text")]
    return "\n\n".join(user_text)[-12000:]


def _attachment_metadata(item: dict[str, Any]) -> list[dict[str, Any]]:
    result = []
    for message in item.get("messages") or []:
        for attachment in message.get("attachments") or []:
            result.append({key: attachment.get(key)
                           for key in ("name", "contentType", "size")})
    return result


def _decision_schema(context: dict[str, Any]) -> dict[str, Any]:
    """Constrain targetId/provider/model/effort to values that exist in the
    allowed targets (and to any hard-requested value). Small local models
    otherwise conflate these fields -- e.g. emitting a model id as the targetId
    and provider -- producing decisions that always fail validation. Grammar-
    constraining the output forces a self-consistent, in-catalog choice."""
    allowed = context.get("allowedTargets") or []
    requested = context.get("requested") or {}

    def enum_for(key: str, values: list[str]) -> dict[str, Any]:
        forced = requested.get(key)
        return {"enum": [forced] if forced is not None else sorted(set(values))}

    schema = copy.deepcopy(DECISION_SCHEMA)
    schema["properties"]["targetId"] = {
        "enum": [target["targetId"] for target in allowed]
    }
    schema["properties"]["provider"] = enum_for(
        "provider", [target["adapter"] for target in allowed])
    schema["properties"]["model"] = enum_for(
        "model", [model for target in allowed for model in target["models"]])
    schema["properties"]["effort"] = enum_for(
        "effort", [effort for target in allowed for effort in target["effortLevels"]])
    return schema


def decide(context: dict[str, Any], timeout: float = 60.0) -> dict[str, Any]:
    if not context.get("allowedTargets"):
        raise RoutingError("needs-human-routing: no enabled available worker target")
    router_target = _router_target()
    endpoint = router_target["endpoint"].rstrip("/")
    prompt = (
        "You are a routing classifier. Select exactly one allowed target. "
        "Honor every non-null requested value as a hard constraint. Prefer "
        "the local free worker for small, low-risk tasks that need only simple "
        "repository inspection or edits; use Codex for complex, broad, visual, "
        "or high-risk work. Prefer the lowest sufficient effort. Return only "
        "the required JSON object; "
        "do not include private reasoning. Routing context:\n" +
        json.dumps(context, separators=(",", ":"), sort_keys=True)
    )
    payload = {
        "model": router_target["models"][0],
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
        "max_tokens": 300,
        "response_format": {
            "type": "json_schema",
            "json_schema": {"name": "routing_decision",
                            "schema": _decision_schema(context)},
        },
    }
    try:
        response = requests.post(f"{endpoint}/v1/chat/completions",
                                 json=payload, timeout=timeout)
        response.raise_for_status()
        content = response.json()["choices"][0]["message"]["content"]
        decision = json.loads(content)
    except (requests.RequestException, KeyError, IndexError, TypeError,
            json.JSONDecodeError) as exc:
        raise RoutingError(f"local router failed: {exc}") from exc
    validate_decision(context, decision)
    return decision


def fallback_decision(
    context: dict[str, Any], catalog: dict[str, Any]
) -> dict[str, Any] | None:
    """Resolve the configured default when the classifier safely abstains."""
    fallback = catalog.get("fallbackAssignment")
    if not fallback:
        return None
    allowed = {
        target["targetId"]: target for target in context.get("allowedTargets", [])
    }
    target = allowed.get(fallback["targetId"])
    if target is None:
        # Availability and explicit user routing constraints remain hard limits.
        return None
    if (fallback["provider"] != target["adapter"] or
            fallback["model"] not in target["models"] or
            fallback["effort"] not in target["effortLevels"]):
        return None
    requested = context.get("requested") or {}
    if any(
        requested.get(key) is not None and requested[key] != fallback[key]
        for key in ("provider", "model", "effort")
    ):
        return None
    decision = {
        "schemaVersion": 1,
        "itemId": context["item"]["id"],
        **fallback,
        "reasonCodes": ["router-abstained", "configured-fallback"],
        "confidence": "high",
    }
    validate_decision(context, decision)
    return decision


def validate_decision(context: dict[str, Any], decision: Any) -> None:
    if not isinstance(decision, dict):
        raise RoutingError("router decision must be an object")
    required = set(DECISION_SCHEMA["required"])
    if set(decision) != required:
        raise RoutingError("router decision has missing or unexpected fields")
    if decision["schemaVersion"] != 1:
        raise RoutingError("unsupported decision schema")
    if decision["itemId"] != context["item"]["id"]:
        raise RoutingError("decision itemId does not match")
    allowed = {target["targetId"]: target for target in context["allowedTargets"]}
    target = allowed.get(decision["targetId"])
    if target is None:
        raise RoutingError("decision target is not currently allowed")
    if decision["provider"] != target["adapter"]:
        raise RoutingError("decision provider does not match target")
    if decision["model"] not in target["models"]:
        raise RoutingError("decision model is not allowed for target")
    if decision["effort"] not in target["effortLevels"]:
        raise RoutingError("decision effort is not allowed for target")
    if decision["confidence"] not in {"low", "medium", "high"}:
        raise RoutingError("invalid confidence")
    confidence_order = {"low": 0, "medium": 1, "high": 2}
    if confidence_order[decision["confidence"]] < confidence_order[config.ROUTER_MIN_CONFIDENCE]:
        raise RoutingError("needs-human-routing: router confidence is too low")
    reasons = decision["reasonCodes"]
    if (not isinstance(reasons, list) or len(reasons) > 5 or
            not all(isinstance(reason, str) and
                    re.fullmatch(r"[a-z0-9-]+", reason) for reason in reasons)):
        raise RoutingError("invalid reasonCodes")
    requested = context.get("requested") or {}
    checks = {
        "provider": decision["provider"],
        "model": decision["model"],
        "effort": decision["effort"],
    }
    for key, actual in checks.items():
        if requested.get(key) is not None and requested[key] != actual:
            raise RoutingError(f"decision violates requested {key}")


def record_shadow(context: dict[str, Any], decision: dict[str, Any]) -> None:
    config.DATA_DIR.mkdir(exist_ok=True)
    record = {
        "recordedAt": datetime.now(timezone.utc).isoformat(),
        "itemId": context["item"]["id"],
        "decision": decision,
    }
    with (config.DATA_DIR / "routing-shadow.jsonl").open("a") as handle:
        handle.write(json.dumps(record, separators=(",", ":")) + "\n")


def _router_target() -> dict[str, Any]:
    catalog = targets.load()
    for target in catalog["targets"]:
        if target["role"] == "router" and target["enabled"]:
            availability = targets.probe(target)
            if not availability["available"]:
                raise RoutingError(f"local router unavailable: {availability['reason']}")
            return target
    raise RoutingError("no enabled local router configured")
