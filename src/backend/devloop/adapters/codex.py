from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any

from .. import config
from .base import COMPLETION_POLICY, WorkerResult


class CodexAdapter:
    def __init__(self, executable: str = "codex", timeout_seconds: int = 3600):
        self.executable = executable
        self.timeout_seconds = timeout_seconds

    def command(self, task: dict[str, Any], output_file: Path) -> list[str]:
        assignment = task["assignment"]
        command = [
            self.executable,
            "exec",
            "--cd", task["repository"]["path"],
            "--ignore-user-config",
            "--dangerously-bypass-approvals-and-sandbox",
            "--json",
            "--output-schema", str(config.WORKER_RESULT_SCHEMA),
            "--output-last-message", str(output_file),
        ]
        model = assignment.get("model")
        if model and model != "default":
            command.extend(["--model", model])
        effort = assignment.get("effort")
        if effort:
            command.extend(["--config", f'model_reasoning_effort="{effort}"'])
        for attachment in task.get("attachments", []):
            path = attachment.get("path")
            content_type = attachment.get("contentType") or ""
            suffix = Path(path).suffix.lower() if isinstance(path, str) else ""
            if (isinstance(path, str) and
                    (content_type.startswith("image/") or
                     suffix in {".png", ".jpg", ".jpeg", ".gif", ".webp"})):
                command.extend(["--image", path])
        command.append("-")
        return command

    def run(self, task: dict[str, Any]) -> WorkerResult:
        run_id = task["runId"]
        if not isinstance(run_id, str) or not run_id.isalnum():
            return WorkerResult(outcome="failed", summary="Invalid trusted run ID.")
        run_dir = config.DATA_DIR / "agent-runs" / "runs" / run_id
        run_dir.mkdir(parents=True, exist_ok=True)
        output = run_dir / "result.json"
        events = run_dir / "provider-events.jsonl"
        prompt = json.dumps({
            "role": "implementation-worker",
            "task": task,
            "requirements": [
                "Follow repository instructions.",
                "Implement and verify the requested work.",
                *COMPLETION_POLICY,
                "Use main and the existing checkout by default.",
                "Do not create a worktree or branch unless instructions require it.",
                "Commit all verified repository changes before returning.",
                "Push the commit to the configured upstream and report any "
                "push failure.",
                "Work only on the requested repository task.",
                "Inspect the provided local attachment paths when relevant.",
                "Do not access dev-loop board credentials or call its board CLI.",
                "Do not change board items, messages, routing, or statuses.",
                "Do not mark anything closed; lifecycle is owned by the dispatcher.",
                "Return only the requested structured final result.",
            ],
        })
        try:
            completed = subprocess.run(
                self.command(task, output), input=prompt, text=True,
                capture_output=True, timeout=self.timeout_seconds,
            )
        except subprocess.TimeoutExpired as exc:
            events.write_text(_text(exc.stdout))
            return WorkerResult(
                outcome="timed-out",
                summary=f"Codex exceeded the {self.timeout_seconds}s timeout.",
            )
        events.write_text(_text(completed.stdout))
        if completed.returncode != 0:
            message = (completed.stderr.strip().splitlines()[-1:]
                       or [_event_error(completed.stdout) or "unknown error"])
            return WorkerResult(outcome="failed",
                                summary=f"Codex failed: {message[0]}")
        try:
            data = json.loads(output.read_text())
            provider_reference = data.get("providerReference") or _thread_id(completed.stdout)
            metadata = data.get("metadata", {})
            metadata["providerEventCount"] = len(completed.stdout.splitlines())
            return WorkerResult(
                outcome=data["outcome"], summary=data["summary"],
                files_changed=data["filesChanged"],
                verification=data["verification"],
                provider_reference=provider_reference,
                metadata=metadata,
            )
        except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
            return WorkerResult(outcome="failed",
                                summary=f"Codex returned an invalid result: {exc}")


def _thread_id(jsonl: str) -> str | None:
    for line in jsonl.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "thread.started" and event.get("thread_id"):
            return str(event["thread_id"])
    return None


def _event_error(jsonl: str) -> str | None:
    messages = []
    for line in jsonl.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "error" and event.get("message"):
            messages.append(str(event["message"]))
        elif event.get("type") == "turn.failed":
            message = (event.get("error") or {}).get("message")
            if message:
                messages.append(str(message))
    return messages[-1] if messages else None


def _text(value: str | bytes | None) -> str:
    if isinstance(value, bytes):
        return value.decode(errors="replace")
    return value or ""
