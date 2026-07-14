from __future__ import annotations

import json
import subprocess
from typing import Any

from .. import config
from .base import WorkerResult


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
            data = envelope.get("structured_output", envelope)
            return WorkerResult(
                outcome=data["outcome"], summary=data["summary"],
                files_changed=data["filesChanged"],
                verification=data["verification"],
                provider_reference=data.get("providerReference"),
                metadata=data.get("metadata", {}),
            )
        except (json.JSONDecodeError, KeyError, TypeError) as exc:
            return WorkerResult(
                outcome="failed",
                summary=f"Claude Code returned an invalid result: {exc}",
            )
