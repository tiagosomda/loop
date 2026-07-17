from __future__ import annotations

import json
import re
import subprocess
from typing import Any

from .. import config
from .base import COMPLETION_POLICY, WorkerResult


class ClaudeAdapter:
    """Trusted Claude Code boundary; catalog-disabled until explicitly enabled."""

    def __init__(self, executable: str = "claude", timeout_seconds: int = 3600):
        self.executable = executable
        self.timeout_seconds = timeout_seconds

    def command(self, task: dict[str, Any]) -> list[str]:
        assignment = task["assignment"]
        command = [
            self.executable, "--print", "--output-format", "json",
            "--dangerously-skip-permissions",
            "--json-schema", config.WORKER_RESULT_SCHEMA.read_text(),
        ]
        if assignment.get("model") not in (None, "default"):
            command.extend(["--model", assignment["model"]])
        if assignment.get("effort"):
            command.extend(["--effort", assignment["effort"]])
        return command

    def run(self, task: dict[str, Any]) -> WorkerResult:
        prompt = json.dumps({
            "task": task,
            "restrictions": [
                "Do not access dev-loop credentials or board APIs.",
                "Do not change board lifecycle or statuses.",
                "Work only in the requested repository.",
                *COMPLETION_POLICY,
                "Commit all verified repository changes before returning.",
                "Push the commit to the configured upstream and report any "
                "push failure.",
            ],
        })
        try:
            completed = subprocess.run(
                self.command(task), cwd=task["repository"]["path"],
                input=prompt, text=True, capture_output=True,
                timeout=self.timeout_seconds,
            )
        except subprocess.TimeoutExpired:
            return WorkerResult(
                outcome="timed-out",
                summary=f"Claude Code exceeded the {self.timeout_seconds}s timeout.",
            )
        if completed.returncode:
            return WorkerResult(outcome="failed", summary="Claude Code failed.")
        try:
            envelope = json.loads(completed.stdout)
        except json.JSONDecodeError as exc:
            return WorkerResult(
                outcome="failed",
                summary=f"Claude Code returned non-JSON output: {exc}",
            )
        if envelope.get("is_error"):
            return WorkerResult(
                outcome="failed",
                summary=(f"Claude Code reported an error "
                         f"({envelope.get('subtype') or 'unknown'})."),
            )
        data = self._worker_result(envelope)
        if data is None:
            return WorkerResult(
                outcome="failed",
                summary="Claude Code did not return a structured worker result.",
            )
        try:
            return WorkerResult(
                outcome=data["outcome"], summary=data["summary"],
                files_changed=data.get("filesChanged", []),
                verification=data.get("verification", []),
                provider_reference=(data.get("providerReference")
                                    or envelope.get("session_id")),
                metadata=data.get("metadata") or {},
            )
        except (KeyError, TypeError) as exc:
            return WorkerResult(
                outcome="failed",
                summary=f"Claude Code returned an invalid result: {exc}",
            )

    @staticmethod
    def _worker_result(envelope: dict[str, Any]) -> dict[str, Any] | None:
        """Recover the structured worker result from a Claude Code json envelope.

        `claude --print --output-format json` returns the model's answer as text
        in `result`, typically wrapped in a ```json ... ``` markdown fence; a
        pre-parsed `structured_output` object is also accepted when present.
        Returns the result mapping, or None when no structured payload exists."""
        candidate = envelope.get("structured_output")
        if isinstance(candidate, dict):
            return candidate
        text = envelope.get("result")
        if not isinstance(text, str):
            return None
        fence = re.match(r"^```(?:json)?\s*(.*?)\s*```$", text.strip(), re.DOTALL)
        try:
            parsed = json.loads(fence.group(1) if fence else text)
        except json.JSONDecodeError:
            return None
        return parsed if isinstance(parsed, dict) else None
