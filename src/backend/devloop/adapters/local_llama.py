from __future__ import annotations

import difflib
import json
import re
import shlex
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

import requests

from .base import WorkerResult


ACTION_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": [
        "action", "path", "lineStart", "lineCount", "query", "patch",
        "command", "outcome", "summary", "verification",
    ],
    "properties": {
        "action": {
            "enum": ["list", "read", "search", "patch", "check", "finish"]
        },
        "path": {"type": "string"},
        "lineStart": {"type": "integer"},
        "lineCount": {"type": "integer"},
        "query": {"type": "string"},
        "patch": {"type": "string"},
        "command": {
            "type": "array", "maxItems": 12,
            "items": {"type": "string"},
        },
        "outcome": {
            "enum": ["succeeded", "needs-review", "failed"]
        },
        "summary": {"type": "string"},
        "verification": {
            "type": "array", "maxItems": 8,
            "items": {"type": "string"},
        },
    },
}

_ALLOWED_CHECKS = {
    "pytest", "python", "python3", "flutter", "dart", "npm", "pnpm",
    "yarn", "cargo", "go", "make", "git",
}
_GIT_CHECKS = {"status", "diff"}
_PYTHON_MODULES = {"pytest", "unittest"}
_PACKAGE_CHECKS = {"test", "run"}
_MAKE_CHECKS = {"test", "check", "lint", "verify"}


class LocalLlamaAdapter:
    """Small, bounded coding loop over the existing local llama.cpp server.

    The model never receives a general-purpose shell. It can inspect non-ignored
    repository files, propose a validated Git patch, and invoke a small set of
    verification commands without network access. Delivery remains deterministic:
    this trusted boundary commits changed paths and pushes when an upstream exists.
    """

    def __init__(self, endpoint: str, *, timeout_seconds: int = 900,
                 request_timeout: float = 90.0, max_turns: int = 16):
        endpoint = endpoint.rstrip("/")
        if not re.fullmatch(r"http://127\.0\.0\.1:\d+", endpoint):
            raise ValueError("local worker endpoint must use 127.0.0.1")
        self.endpoint = endpoint
        self.timeout_seconds = timeout_seconds
        self.request_timeout = request_timeout
        self.max_turns = max_turns

    def run(self, task: dict[str, Any]) -> WorkerResult:
        repo = Path(task["repository"]["path"]).resolve()
        if not repo.is_dir():
            return WorkerResult(outcome="failed", summary="Local worker repository is missing.")
        transcript = _bootstrap_transcript(task, repo)
        patched_paths: set[str] = set()
        started = time.monotonic()

        for turn in range(1, self.max_turns + 1):
            remaining = self.timeout_seconds - (time.monotonic() - started)
            if remaining <= 0:
                return WorkerResult(
                    outcome="timed-out",
                    summary=f"Local Gemma exceeded the {self.timeout_seconds}s timeout.",
                )
            try:
                action = self._next_action(
                    task, transcript,
                    timeout=min(self.request_timeout, max(1.0, remaining)),
                )
            except requests.Timeout:
                return WorkerResult(
                    outcome="timed-out", summary="Local Gemma request timed out."
                )
            except (requests.RequestException, KeyError, IndexError, TypeError,
                    ValueError, json.JSONDecodeError) as exc:
                return WorkerResult(
                    outcome="failed", summary=f"Local Gemma failed: {exc}"
                )

            kind = action["action"]
            if kind == "finish":
                result = WorkerResult(
                    outcome=action["outcome"],
                    summary=action["summary"] or "Local Gemma finished without a summary.",
                    verification=action["verification"],
                    provider_reference=f"local-{task['runId']}",
                    metadata={"turnCount": turn},
                )
                return self._deliver(task, repo, patched_paths, result)
            if (_is_explicit_read_only(task) and transcript and
                    transcript[0].startswith("Bootstrap read") and
                    action["outcome"] == "succeeded" and action["summary"]):
                return WorkerResult(
                    outcome="succeeded",
                    summary=action["summary"],
                    verification=["Local repository content inspected"],
                    provider_reference=f"local-{task['runId']}",
                    metadata={"turnCount": turn},
                )

            tool_succeeded = True
            try:
                observation = self._execute(kind, action, repo, patched_paths)
            except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
                tool_succeeded = False
                observation = f"Tool error: {type(exc).__name__}: {exc}"
            transcript.append(
                f"Turn {turn}: {kind}\n{_clip(observation, 7000)}"
            )
            if kind == "patch" and tool_succeeded and action["outcome"] == "succeeded":
                try:
                    checked = _sandboxed_check(repo, ["git", "diff", "--check"])
                    _command_output(checked)
                except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
                    transcript.append(f"Automatic verification error: {exc}")
                    continue
                result = WorkerResult(
                    outcome="succeeded",
                    summary=action["summary"] or "Local Gemma applied the requested patch.",
                    verification=["git diff --check"],
                    provider_reference=f"local-{task['runId']}",
                    metadata={"turnCount": turn},
                )
                return self._deliver(task, repo, patched_paths, result)

        return WorkerResult(
            outcome="failed",
            summary=f"Local Gemma reached the {self.max_turns}-turn limit.",
            provider_reference=f"local-{task['runId']}",
            metadata={"turnCount": self.max_turns},
        )

    def _next_action(self, task: dict[str, Any], transcript: list[str], *,
                     timeout: float) -> dict[str, Any]:
        assignment = task["assignment"]
        request = "\n".join(
            f"{message.get('author', 'user')}: "
            f"{_clip(str(message.get('text')), 1200)}"
            for message in task.get("request", [])[-4:]
            if message.get("text")
        )
        recent = "\n\n".join(_clip(value, 1800) for value in transcript[-2:])
        prompt = f"""You are a small local coding worker. Complete only a small,
low-risk repository task.

TITLE: {task.get('title') or ''}
USER REQUEST:
{request}
BRANCH: {task['repository'].get('branch') or ''}
STARTING STATUS: {task['repository'].get('status', [])}

LATEST TOOL RESULTS (these are facts; use them and never repeat a successful action):
{recent or '(none yet)'}

Choose exactly one next action:
- list: list repository files; set path.
- read: read a file; set path, lineStart, lineCount.
- search: search repository text; set query and optional path.
- patch: apply a unified Git patch. Exact example:
  diff --git a/README.md b/README.md
  --- a/README.md
  +++ b/README.md
  @@ -1 +1 @@
  -old text
  +new text
- check: run a test/lint command; set command to an argv array.
- finish: return the result; set outcome, summary, verification.

Rules:
- Fill every unused field with an empty string, empty array, or 1 for line numbers.
- Always inspect before editing. After a successful read, do not read the same file again.
- If an inspection-only request is answered by the latest tool result, finish now and
  quote the actual result in the summary.
- For edits: inspect, patch, check, then finish. Never fabricate tool results.
- Never read ignored files, secrets, credentials, or paths outside the repository.
- Never use the network. If the task is complex or needs images, finish needs-review.
- Use succeeded only when complete; use needs-review only for a specific blocker.
- The trusted adapter commits and pushes after finish.
"""
        payload = {
            "model": assignment["model"],
            "messages": [{
                "role": "user",
                "content": prompt,
            }],
            "temperature": 0,
            "max_tokens": 900,
            "response_format": {
                "type": "json_schema",
                "json_schema": {"name": "local_worker_action", "schema": ACTION_SCHEMA},
            },
        }
        response = requests.post(
            f"{self.endpoint}/v1/chat/completions", json=payload, timeout=timeout
        )
        response.raise_for_status()
        action = json.loads(response.json()["choices"][0]["message"]["content"])
        if not isinstance(action, dict) or set(action) != set(ACTION_SCHEMA["required"]):
            raise ValueError("local worker returned an invalid action shape")
        if (not isinstance(action["action"], str) or
                not isinstance(action["path"], str) or
                not isinstance(action["lineStart"], int) or
                not isinstance(action["lineCount"], int) or
                not isinstance(action["query"], str) or
                not isinstance(action["patch"], str) or
                not isinstance(action["command"], list) or
                not isinstance(action["outcome"], str) or
                not isinstance(action["summary"], str) or
                not isinstance(action["verification"], list)):
            raise ValueError("local worker returned invalid action values")
        action["lineStart"] = max(1, action["lineStart"])
        action["lineCount"] = min(200, max(1, action["lineCount"]))
        action["summary"] = action["summary"][:2000]
        action["verification"] = [str(value)[:500]
                                  for value in action["verification"][:8]]
        return action

    def _execute(self, kind: str, action: dict[str, Any], repo: Path,
                 patched_paths: set[str]) -> str:
        if kind == "list":
            relative = action["path"] or "."
            root = _safe_path(repo, relative, allow_directory=True)
            prefix = "." if root == repo else str(root.relative_to(repo))
            completed = subprocess.run(
                ["rg", "--files", prefix], cwd=repo, text=True,
                capture_output=True, timeout=10,
            )
            return _command_output(completed)
        if kind == "read":
            path = _safe_path(repo, action["path"])
            _reject_ignored(repo, path)
            lines = path.read_text(errors="replace").splitlines()
            start = action["lineStart"] - 1
            selected = lines[start:start + action["lineCount"]]
            return "\n".join(
                f"{number}: {line}"
                for number, line in enumerate(selected, start=start + 1)
            ) or "(no lines in range)"
        if kind == "search":
            if not action["query"]:
                raise ValueError("search query is required")
            relative = action["path"] or "."
            _safe_path(repo, relative, allow_directory=True)
            completed = subprocess.run(
                ["rg", "-n", "--hidden", "--glob", "!.git", "--glob", "!data",
                 "--", action["query"], relative],
                cwd=repo, text=True, capture_output=True, timeout=10,
            )
            return _command_output(completed, allowed_codes={0, 1})
        if kind == "patch":
            patch = _normalize_patch(repo, action["patch"], action)
            paths = _validate_patch(repo, patch)
            completed = subprocess.run(
                ["git", "apply", "--recount", "--whitespace=nowarn", "-"],
                cwd=repo, input=patch, text=True,
                capture_output=True, timeout=20,
            )
            output = _command_output(completed)
            patched_paths.update(paths)
            return output or f"Patch applied to: {', '.join(sorted(paths))}"
        if kind == "check":
            command = _validate_check_command(action["command"])
            completed = _sandboxed_check(repo, command)
            return _command_output(completed)
        raise ValueError(f"unknown local worker action {kind!r}")

    def _deliver(self, task: dict[str, Any], repo: Path, patched_paths: set[str],
                 result: WorkerResult) -> WorkerResult:
        if result.outcome != "succeeded" or not patched_paths:
            result.files_changed = sorted(patched_paths)
            return result
        existing = [path for path in sorted(patched_paths)
                    if (repo / path).exists() or _is_tracked(repo, path)]
        if not existing:
            return result
        try:
            _git(repo, "add", "--", *existing)
            staged = subprocess.run(
                ["git", "diff", "--cached", "--quiet"], cwd=repo,
                capture_output=True, timeout=20,
            )
            if staged.returncode == 0:
                result.files_changed = []
                return result
            if staged.returncode != 1:
                raise RuntimeError("could not inspect staged local-worker changes")
            title = re.sub(r"\s+", " ", str(task.get("title") or "complete item")).strip()
            _git(repo, "commit", "-m", f"dev-loop: {title[:60]}", timeout=90)
            upstream = subprocess.run(
                ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name",
                 "@{upstream}"], cwd=repo, text=True, capture_output=True, timeout=20,
            )
            if upstream.returncode == 0:
                _git(repo, "push", timeout=180)
            result.files_changed = _changed_since_start(task, repo, patched_paths)
            result.metadata["delivery"] = (
                "committed-and-pushed" if upstream.returncode == 0 else "committed-no-upstream"
            )
            return result
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
            return WorkerResult(
                outcome="needs-review",
                summary=f"{result.summary} Local Git delivery failed: {exc}.",
                files_changed=sorted(patched_paths),
                verification=result.verification,
                provider_reference=result.provider_reference,
                metadata=result.metadata,
            )


def _clip(value: str, limit: int) -> str:
    return value if len(value) <= limit else value[-limit:]


def _bootstrap_transcript(task: dict[str, Any], repo: Path) -> list[str]:
    """Seed small-model context with files explicitly named by the request."""
    request = "\n".join(
        str(message.get("text") or "") for message in task.get("request", [])
    ).lower()
    completed = subprocess.run(
        ["git", "ls-files"], cwd=repo, text=True, capture_output=True, timeout=20,
    )
    if completed.returncode:
        return []
    files = [line for line in completed.stdout.splitlines() if line]
    mentioned = [
        path for path in files
        if path.lower() in request or Path(path).name.lower() in request
    ]
    if not mentioned:
        listing = "\n".join(files[:250])
        return [f"Bootstrap repository file list:\n{_clip(listing, 3000)}"]
    transcript = []
    for relative in mentioned[:1]:
        path = _safe_path(repo, relative)
        _reject_ignored(repo, path)
        lines = path.read_text(errors="replace").splitlines()[:120]
        content = "\n".join(
            f"{number}: {line}" for number, line in enumerate(lines, start=1)
        )
        transcript.append(
            f"Bootstrap read {relative}:\n{_clip(content, 3500)}"
        )
    return transcript


def _is_explicit_read_only(task: dict[str, Any]) -> bool:
    request = " ".join(
        str(message.get("text") or "") for message in task.get("request", [])
    ).lower()
    return any(phrase in request for phrase in (
        "no edits", "do not edit", "don't edit", "make no changes",
        "without changes", "read-only",
    ))


def _safe_path(repo: Path, relative: str, *, allow_directory: bool = False) -> Path:
    repo = repo.resolve()
    if not relative or Path(relative).is_absolute():
        raise ValueError("path must be repository-relative")
    requested = repo / relative
    if not allow_directory and not requested.exists() and not requested.suffix:
        matches = [candidate for candidate in requested.parent.glob(
            f"{requested.name}.*"
        ) if candidate.is_file()]
        if len(matches) == 1:
            requested = matches[0]
    if requested.is_symlink():
        raise ValueError("symbolic links are not allowed")
    path = requested.resolve()
    if path != repo and repo not in path.parents:
        raise ValueError("path escapes the repository")
    if ".git" in path.relative_to(repo).parts:
        raise ValueError("direct .git access is not allowed")
    if allow_directory:
        if not path.is_dir():
            raise ValueError("directory does not exist")
    elif not path.is_file():
        raise ValueError("file does not exist")
    return path


def _reject_ignored(repo: Path, path: Path) -> None:
    relative = str(path.relative_to(repo))
    ignored = subprocess.run(
        ["git", "check-ignore", "-q", "--", relative], cwd=repo,
        capture_output=True, timeout=10,
    )
    if ignored.returncode == 0:
        raise ValueError("ignored files cannot be read")


def _validate_patch(repo: Path, patch: str) -> set[str]:
    repo = repo.resolve()
    if not patch or len(patch) > 100000:
        raise ValueError("patch is empty or too large")
    paths: set[str] = set()
    for marker in re.findall(r"^(?:---|\+\+\+)\s+([^\t\n]+)", patch, re.MULTILINE):
        if marker == "/dev/null":
            continue
        relative = marker[2:] if marker.startswith(("a/", "b/")) else marker
        candidate = (repo / relative).resolve()
        if candidate != repo and repo not in candidate.parents:
            raise ValueError("patch path escapes the repository")
        if ".git" in candidate.relative_to(repo).parts:
            raise ValueError("patch cannot modify .git")
        if candidate.exists():
            _reject_ignored(repo, candidate)
        paths.add(relative)
    if not paths:
        raise ValueError("patch has no repository file paths")
    return paths


def _normalize_patch(repo: Path, patch: str,
                     action: dict[str, Any] | None = None) -> str:
    """Accept Gemma's common two-line edit shorthand and make a real diff."""
    unified = re.search(
        r"--- a/(?P<path>[^\n]+)\n\+\+\+ b/(?P=path)\n"
        r"@@ -(?P<line>\d+)(?:,1)? \+(?P=line)(?:,1)? @@[^\n]*\n"
        r"-(?P<old>[^\n]*)\n\+(?P<new>[^\n]*)",
        patch,
    )
    if unified is not None:
        repaired = _single_line_diff(
            repo, unified.group("path"), int(unified.group("line")),
            unified.group("old"), unified.group("new"),
        )
        return repaired or patch
    if re.search(r"^(?:---|\+\+\+)\s+", patch, re.MULTILINE):
        return patch
    match = re.fullmatch(
        r"a/(?P<path>[^:\n]+):(?P<line>\d+):(?P<old>[^\n]*)\n"
        r"b/(?P=path):(?P=line):(?P<new>[^\n]*)\n?",
        patch,
    )
    if match is None:
        if (action and action.get("path") and action.get("query") and
                isinstance(action.get("lineStart"), int)):
            replacement = patch.strip("\r\n")
            old = action["query"]
            if old.startswith("# ") and replacement.startswith("## "):
                replacement = replacement[1:]
            repaired = _single_line_diff(
                repo, action["path"], action["lineStart"], old, replacement,
            )
            if repaired:
                return repaired
        return patch
    repaired = _single_line_diff(
        repo, match.group("path"), int(match.group("line")),
        match.group("old"), match.group("new"),
    )
    return repaired or patch


def _single_line_diff(repo: Path, relative: str, line_number: int,
                      old: str, new: str) -> str | None:
    repo = repo.resolve()
    path = _safe_path(repo, relative)
    _reject_ignored(repo, path)
    original = path.read_text(errors="replace").splitlines(keepends=True)
    line_index = line_number - 1
    if line_index < 0 or line_index >= len(original):
        raise ValueError("shorthand patch line is outside the file")
    actual = original[line_index].rstrip("\r\n")
    if actual == old:
        replacement = new
    elif old and actual.endswith(old):
        replacement = actual[:-len(old)] + new
    else:
        return None
    updated = list(original)
    ending = "\n" if original[line_index].endswith("\n") else ""
    updated[line_index] = replacement + ending
    return "".join(difflib.unified_diff(
        original, updated, fromfile=f"a/{relative}", tofile=f"b/{relative}",
    ))


def _validate_check_command(command: Any) -> list[str]:
    if (not isinstance(command, list) or not command or
            not all(isinstance(part, str) and part for part in command)):
        raise ValueError("check command must be a non-empty argv array")
    executable = Path(command[0]).name
    if executable not in _ALLOWED_CHECKS:
        raise ValueError(f"check executable {executable!r} is not allowed")
    args = command[1:]
    if executable == "git" and (not args or args[0] not in _GIT_CHECKS):
        raise ValueError("only git status and git diff checks are allowed")
    if executable in {"python", "python3"} and (
        len(args) < 2 or args[0] != "-m" or args[1] not in _PYTHON_MODULES
    ):
        raise ValueError("Python checks must use -m pytest or -m unittest")
    if executable in {"npm", "pnpm", "yarn"} and (
        not args or args[0] not in _PACKAGE_CHECKS
    ):
        raise ValueError("package-manager checks must use test or run")
    if executable == "make" and (not args or args[0] not in _MAKE_CHECKS):
        raise ValueError("make checks are limited to test/check/lint/verify")
    return command


def _sandboxed_check(repo: Path, command: list[str]) -> subprocess.CompletedProcess[str]:
    quoted_repo = str(repo).replace('"', '\\"')
    profile = (
        '(version 1) (deny default) (allow process*) (allow sysctl-read) '
        '(allow file-read*) '
        f'(allow file-write* (subpath "{quoted_repo}")) '
        '(allow file-write* (subpath "/private/tmp")) '
        '(allow file-write* (literal "/dev/null"))'
    )
    executable = command[0]
    if executable == "git":
        resolved = subprocess.run(
            ["xcrun", "-f", "git"], text=True, capture_output=True, timeout=10,
        )
        if resolved.returncode == 0 and resolved.stdout.strip():
            executable = resolved.stdout.strip()
    else:
        executable = shutil.which(executable) or executable
    return subprocess.run(
        ["sandbox-exec", "-p", profile, executable, *command[1:]],
        cwd=repo, text=True,
        capture_output=True, timeout=300,
    )


def _command_output(completed: subprocess.CompletedProcess[str], *,
                    allowed_codes: set[int] | None = None) -> str:
    allowed = allowed_codes or {0}
    output = "\n".join(
        part.strip() for part in (completed.stdout, completed.stderr) if part.strip()
    )
    if completed.returncode not in allowed:
        command = shlex.join(str(part) for part in completed.args)
        raise RuntimeError(
            f"{command} exited {completed.returncode}: {_clip(output, 3000)}"
        )
    return _clip(output, 12000)


def _git(repo: Path, *args: str, timeout: int = 60) -> str:
    completed = subprocess.run(
        ["git", *args], cwd=repo, text=True, capture_output=True, timeout=timeout,
    )
    return _command_output(completed)


def _is_tracked(repo: Path, path: str) -> bool:
    return subprocess.run(
        ["git", "ls-files", "--error-unmatch", "--", path], cwd=repo,
        capture_output=True, timeout=10,
    ).returncode == 0


def _changed_since_start(task: dict[str, Any], repo: Path,
                         fallback: set[str]) -> list[str]:
    revision = task["repository"].get("startingRevision")
    if not revision:
        return sorted(fallback)
    completed = subprocess.run(
        ["git", "diff", "--name-only", f"{revision}..HEAD"], cwd=repo,
        text=True, capture_output=True, timeout=20,
    )
    if completed.returncode:
        return sorted(fallback)
    return [line for line in completed.stdout.splitlines() if line]
