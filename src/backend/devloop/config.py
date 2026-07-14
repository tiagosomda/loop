"""Shared configuration for the dev-loop backend.

The Firestore database is shared with other projects (match-chat, ...), so
every document we touch lives under the root-level `dev-loop` collection.
"""

from __future__ import annotations

import os
from pathlib import Path

PROJECT_ID = "tiago-dev-site"
STORAGE_BUCKET = "tiago-dev-site.firebasestorage.app"

# Firestore paths (shared database — never write outside dev-loop/).
ROOT_DOC = "dev-loop/app"
ITEMS = f"{ROOT_DOC}/items"
REPOS = f"{ROOT_DOC}/repos"
SCHEDULE_DOC = f"{ROOT_DOC}/meta/schedule"
TARGETS_DOC = f"{ROOT_DOC}/meta/targets"

# Attachments live under this Storage prefix.
ATTACHMENTS_PREFIX = "dev-loop/attachments"

ITEM_STATUSES = ("open", "in-progress", "needs-review", "completed", "closed")

# Local times the scheduled agent wakes up (see docs/design.md).
SCHEDULE_TIMES = ("00:15", "05:15", "10:15", "15:15", "20:15")

REPO_ROOT = Path(__file__).resolve().parents[3]
DATA_DIR = REPO_ROOT / "data"
DEV_ROOT = REPO_ROOT / "dev"
RULES_DIR = Path(__file__).resolve().parents[1] / "rules"
TARGETS_FILE = Path(__file__).resolve().parents[1] / "config" / "targets.json"
WORKER_RESULT_SCHEMA = (Path(__file__).resolve().parents[1] /
                        "config" / "worker-result.schema.json")


def service_account_path() -> Path:
    """Resolve the service-account JSON for project tiago-dev-site."""
    candidates = [
        os.environ.get("DEV_LOOP_SERVICE_ACCOUNT"),
        DATA_DIR / "service-account.json",
        # Reuse match-chat's poller credential (same Firebase project).
        DEV_ROOT / "tiagosomda/match-chat/src/backend/poller/service-account.json",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    raise SystemExit(
        "No service account found. Set $DEV_LOOP_SERVICE_ACCOUNT or place the "
        "JSON at data/service-account.json"
    )
