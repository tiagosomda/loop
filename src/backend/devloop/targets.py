"""Versioned target catalog, validation, and deterministic availability probes."""

from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Any

import requests

from . import config

_REQUIRED_TARGET_FIELDS = {
    "targetId", "role", "adapter", "location", "enabled", "models",
    "effortLevels", "supportsImages", "supportsRepositoryWrites",
    "supportsNetwork", "costTier", "concurrencyLimit",
}
_ROLES = {"router", "worker"}
_LOCATIONS = {"local", "cloud"}
_EFFORTS = {"low", "medium", "high", "max"}
_SAFE_FIELDS = (
    "targetId", "role", "adapter", "location", "models", "effortLevels",
    "contextLimit", "supportsImages", "supportsRepositoryWrites",
    "supportsNetwork", "costTier", "concurrencyLimit",
)


class CatalogError(ValueError):
    """The trusted target catalog is internally inconsistent."""


def load(path: Path | None = None) -> dict[str, Any]:
    catalog_path = path or config.TARGETS_FILE
    try:
        catalog = json.loads(catalog_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise CatalogError(f"cannot load target catalog {catalog_path}: {exc}") from exc
    validate(catalog)
    return catalog


def validate(catalog: dict[str, Any]) -> None:
    if catalog.get("schemaVersion") != 1:
        raise CatalogError("unsupported or missing schemaVersion")
    if not isinstance(catalog.get("catalogVersion"), str):
        raise CatalogError("catalogVersion must be a string")
    targets = catalog.get("targets")
    if not isinstance(targets, list):
        raise CatalogError("targets must be a list")

    seen: set[str] = set()
    for target in targets:
        if not isinstance(target, dict):
            raise CatalogError("each target must be an object")
        missing = _REQUIRED_TARGET_FIELDS - target.keys()
        if missing:
            raise CatalogError(f"target missing fields: {sorted(missing)}")
        target_id = target["targetId"]
        if not isinstance(target_id, str) or not target_id:
            raise CatalogError("targetId must be a non-empty string")
        if target_id in seen:
            raise CatalogError(f"duplicate targetId {target_id!r}")
        seen.add(target_id)
        if target["role"] not in _ROLES:
            raise CatalogError(f"invalid role for {target_id!r}")
        if target["location"] not in _LOCATIONS:
            raise CatalogError(f"invalid location for {target_id!r}")
        if not isinstance(target["enabled"], bool):
            raise CatalogError(f"enabled must be boolean for {target_id!r}")
        if not _nonempty_strings(target["models"]):
            raise CatalogError(f"models must be non-empty strings for {target_id!r}")
        if (not _nonempty_strings(target["effortLevels"]) or
                not set(target["effortLevels"]).issubset(_EFFORTS)):
            raise CatalogError(f"invalid effortLevels for {target_id!r}")
        if not isinstance(target["concurrencyLimit"], int) or target["concurrencyLimit"] < 1:
            raise CatalogError(f"invalid concurrencyLimit for {target_id!r}")


def _nonempty_strings(value: Any) -> bool:
    return (isinstance(value, list) and bool(value) and
            all(isinstance(entry, str) and entry for entry in value))


def probe(target: dict[str, Any], timeout: float = 1.0) -> dict[str, Any]:
    if not target["enabled"]:
        return {"available": False, "reason": "disabled-by-configuration"}

    adapter = target["adapter"]
    if adapter == "llama-cpp":
        endpoint = target.get("endpoint")
        if not isinstance(endpoint, str) or not endpoint.startswith("http://127.0.0.1:"):
            return {"available": False, "reason": "invalid-local-endpoint"}
        try:
            response = requests.get(f"{endpoint.rstrip('/')}/health", timeout=timeout)
            response.raise_for_status()
            healthy = response.json().get("status") == "ok"
        except (requests.RequestException, ValueError):
            return {"available": False, "reason": "health-check-failed"}
        return {"available": healthy,
                "reason": "healthy" if healthy else "unhealthy-response"}

    executable = target.get("executable")
    if not isinstance(executable, str) or not executable:
        return {"available": False, "reason": "missing-executable-configuration"}
    path = shutil.which(executable)
    return ({"available": True, "reason": "executable-found"}
            if path else
            {"available": False, "reason": "executable-not-found"})


def safe_projection(*, role: str | None = None, enabled_only: bool = False,
                    include_availability: bool = True,
                    path: Path | None = None) -> dict[str, Any]:
    if role is not None and role not in _ROLES:
        raise CatalogError(f"invalid role filter {role!r}")
    catalog = load(path)
    projected = []
    for target in catalog["targets"]:
        if role and target["role"] != role:
            continue
        if enabled_only and not target["enabled"]:
            continue
        public = {key: target[key] for key in _SAFE_FIELDS if key in target}
        public["enabled"] = target["enabled"]
        if include_availability:
            public["availability"] = probe(target)
        projected.append(public)
    return {
        "schemaVersion": catalog["schemaVersion"],
        "catalogVersion": catalog["catalogVersion"],
        "targets": projected,
    }


def enabled_available_workers(path: Path | None = None) -> list[dict[str, Any]]:
    projection = safe_projection(role="worker", enabled_only=True, path=path)
    return [target for target in projection["targets"]
            if target["availability"]["available"]]
