"""Crawl the dev/ root for git repos and mirror them into Firestore.

Repos that disappear from disk are marked `removed` (not deleted): they stop
showing up when creating a new action item but remain visible on the profile
screen until the user clears them.
"""

from __future__ import annotations

import configparser
from pathlib import Path

from firebase_admin import firestore

from . import config, fs

MAX_DEPTH = 3


def _remote_url(repo_dir: Path) -> str | None:
    git_config = repo_dir / ".git" / "config"
    if not git_config.is_file():
        return None
    parser = configparser.ConfigParser()
    try:
        parser.read(git_config)
        return parser.get('remote "origin"', "url", fallback=None)
    except configparser.Error:
        return None


def _host(remote: str | None) -> str | None:
    if not remote:
        return None
    if "github" in remote:
        return "github"
    if "gitlab" in remote:
        return "gitlab"
    return "other"


def _find_repos(root: Path) -> list[Path]:
    found: list[Path] = []

    def walk(directory: Path, depth: int) -> None:
        if (directory / ".git").is_dir():
            found.append(directory)
            return  # don't descend into a repo looking for nested repos
        if depth >= MAX_DEPTH:
            return
        for child in sorted(directory.iterdir()):
            if child.is_dir() and not child.name.startswith("."):
                walk(child, depth + 1)

    walk(root, 0)
    return found


def get(repo_id: str) -> dict | None:
    """Look up one repo's registry doc (path is relative to config.DEV_ROOT)."""
    doc = fs.db().collection(config.REPOS).document(repo_id).get()
    return doc.to_dict() if doc.exists else None


def crawl() -> dict:
    root = config.DEV_ROOT.resolve()
    if not root.is_dir():
        raise SystemExit(f"dev root not found at {config.DEV_ROOT} (create the symlink)")

    collection = fs.db().collection(config.REPOS)
    existing = {doc.id: (doc.to_dict() or {}) for doc in collection.stream()}
    seen: set[str] = set()

    for repo_dir in _find_repos(root):
        rel = repo_dir.relative_to(root)
        repo_id = str(rel).replace("/", "__")
        seen.add(repo_id)
        remote = _remote_url(repo_dir)
        collection.document(repo_id).set(
            {
                "name": repo_dir.name,
                "path": str(rel),
                "remote": remote,
                "host": _host(remote),
                "status": "active",
                "lastSeenAt": firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )

    removed = []
    for repo_id, data in existing.items():
        if repo_id not in seen and data.get("status") == "active":
            collection.document(repo_id).update({"status": "removed"})
            removed.append(repo_id)

    return {"active": sorted(seen), "removed": removed}
