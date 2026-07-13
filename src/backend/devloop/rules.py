"""Manage the SHARED Firestore/Storage security rules.

The deployed ruleset also contains other projects' rules (match-chat, ...).
Never deploy a file that only holds dev-loop rules. The safe flow is:

    pull    download the currently released ruleset -> data/
    merge   splice rules/dev-loop.rules into it between markers -> data/
    deploy  upload the merged file and release it (after confirmation)

Uses the Firebase Rules REST API authenticated with the service account.
"""

from __future__ import annotations

import google.auth.transport.requests
from google.oauth2 import service_account

from . import config

API = "https://firebaserules.googleapis.com/v1"

MARKER_START = "// === dev-loop rules start (managed by the dev-loop repo) ==="
MARKER_END = "// === dev-loop rules end ==="

_SERVICES = {
    "firestore": {
        "release": f"projects/{config.PROJECT_ID}/releases/cloud.firestore",
        "file_name": "firestore.rules",
        "snippet": config.RULES_DIR / "dev-loop.rules",
        # our block nests inside this match
        "container": "match /databases/{database}/documents {",
    },
    "storage": {
        "release": (
            f"projects/{config.PROJECT_ID}/releases/"
            f"firebase.storage/{config.STORAGE_BUCKET}"
        ),
        "file_name": "storage.rules",
        "snippet": config.RULES_DIR / "dev-loop.storage.rules",
        "container": "match /b/{bucket}/o {",
    },
}


def _session():
    creds = service_account.Credentials.from_service_account_file(
        str(config.service_account_path()),
        scopes=["https://www.googleapis.com/auth/cloud-platform"],
    )
    return google.auth.transport.requests.AuthorizedSession(creds)


def _paths(service: str) -> tuple:
    spec = _SERVICES[service]
    current = config.DATA_DIR / f"{spec['file_name']}.current"
    merged = config.DATA_DIR / f"{spec['file_name']}.merged"
    return spec, current, merged


_BASELINES = {
    # First-time bootstrap when no ruleset has ever been released: default
    # deny-all skeletons our merge step can splice the dev-loop section into.
    "storage": (
        "rules_version = '2';\n"
        "service firebase.storage {\n"
        "  match /b/{bucket}/o {\n"
        "    match /{allPaths=**} {\n"
        "      allow read, write: if false;\n"
        "    }\n"
        "  }\n"
        "}\n"
    ),
    "firestore": (
        "rules_version = '2';\n"
        "service cloud.firestore {\n"
        "  match /databases/{database}/documents {\n"
        "    match /{document=**} {\n"
        "      allow read, write: if false;\n"
        "    }\n"
        "  }\n"
        "}\n"
    ),
}


def pull(service: str) -> str:
    spec, current, _ = _paths(service)
    session = _session()
    release = session.get(f"{API}/{spec['release']}")
    if release.status_code == 404:
        print(f"no released {service} ruleset yet — writing deny-all baseline")
        source = _BASELINES[service]
    else:
        release.raise_for_status()
        ruleset_name = release.json()["rulesetName"]
        ruleset = session.get(f"{API}/{ruleset_name}")
        ruleset.raise_for_status()
        source = ruleset.json()["source"]["files"][0]["content"]
    config.DATA_DIR.mkdir(exist_ok=True)
    current.write_text(source)
    return str(current)


def _close_of(text: str, container: str) -> int:
    """Index of the closing brace of the given container match block."""
    start = text.index(container) + len(container)
    depth = 1
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    raise SystemExit(f"unbalanced braces after {container!r}")


def merge(service: str) -> str:
    spec, current, merged_path = _paths(service)
    if not current.is_file():
        raise SystemExit(f"{current} not found — run `rules pull` first")
    full = current.read_text()
    snippet = spec["snippet"].read_text().strip("\n")
    indented = "\n".join(
        f"    {line}" if line else "" for line in snippet.splitlines()
    )
    block = f"{indented}\n"

    if MARKER_START in full:
        before = full[: full.index(MARKER_START)].rstrip(" ")
        after = full[full.index(MARKER_END) + len(MARKER_END):].lstrip("\n")
        # markers are part of the snippet file, so re-insert just the block
        merged = f"{before.rstrip()}\n\n{block}{after}"
    else:
        close = _close_of(full, spec["container"])
        merged = f"{full[:close].rstrip()}\n\n{block}  {full[close:].lstrip()}"

    merged_path.write_text(merged)
    return str(merged_path)


def deploy(service: str, yes: bool = False) -> str:
    spec, _, merged_path = _paths(service)
    if not merged_path.is_file():
        raise SystemExit(f"{merged_path} not found — run `rules merge` first")
    content = merged_path.read_text()
    if MARKER_START not in content:
        raise SystemExit("merged file lacks the dev-loop markers; refusing to deploy")
    if not yes:
        print(f"About to release {merged_path} as the FULL shared {service} ruleset.")
        if input("Type 'deploy' to continue: ").strip() != "deploy":
            raise SystemExit("aborted")

    session = _session()
    ruleset = session.post(
        f"{API}/projects/{config.PROJECT_ID}/rulesets",
        json={"source": {"files": [{"name": spec["file_name"], "content": content}]}},
    )
    ruleset.raise_for_status()
    ruleset_name = ruleset.json()["name"]
    body = {"name": spec["release"], "rulesetName": ruleset_name}
    release = session.patch(f"{API}/{spec['release']}", json={"release": body})
    if release.status_code == 404:
        # first release for this service/bucket
        release = session.post(
            f"{API}/projects/{config.PROJECT_ID}/releases", json=body
        )
    release.raise_for_status()
    return ruleset_name
