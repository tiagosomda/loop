from __future__ import annotations

import json
import subprocess
from typing import Any

from .base import WorkerResult


class ClaudeAdapter:
    """Trusted Claude Code boundary; catalog-disabled until explicitly enabled."""

    def __init__(self, executable: str = "claude", timeout_seconds: int = 3600):
        self.executable = executable
        self.timeout_seconds = timeout_seconds

    def run(self, task: dict[str, Any]) -> WorkerResult:
        completed = subprocess.run(
            [self.executable, "--print", "--output-format", "json",
             "--dangerously-skip-permissions"],
            cwd=task["repository"]["path"], input=json.dumps(task), text=True,
            capture_output=True, timeout=self.timeout_seconds,
        )
        if completed.returncode:
            return WorkerResult(outcome="failed", summary="Claude Code failed.")
        return WorkerResult(
            outcome="needs-review",
            summary="Claude Code completed; structured normalization is pending rollout.",
            metadata={"rawOutputCaptured": bool(completed.stdout)},
        )
