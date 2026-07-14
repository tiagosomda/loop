from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from .. import config
from .base import WorkerResult


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
        command.append("-")
        return command

    def run(self, task: dict[str, Any]) -> WorkerResult:
        config.DATA_DIR.mkdir(exist_ok=True)
        prompt = json.dumps({
            "role": "implementation-worker",
            "task": task,
            "requirements": [
                "Follow repository instructions.",
                "Implement and verify the requested work.",
                "Use main and the existing checkout by default.",
                "Do not create a worktree or branch unless instructions require it.",
                "Return only the requested structured final result.",
            ],
        })
        with tempfile.TemporaryDirectory(dir=config.DATA_DIR) as directory:
            output = Path(directory) / "result.json"
            try:
                completed = subprocess.run(
                    self.command(task, output), input=prompt, text=True,
                    capture_output=True, timeout=self.timeout_seconds,
                )
            except subprocess.TimeoutExpired:
                return WorkerResult(
                    outcome="timed-out",
                    summary=f"Codex exceeded the {self.timeout_seconds}s timeout.",
                )
            if completed.returncode != 0:
                message = completed.stderr.strip().splitlines()[-1:] or ["unknown error"]
                return WorkerResult(outcome="failed",
                                    summary=f"Codex failed: {message[0]}")
            try:
                data = json.loads(output.read_text())
                return WorkerResult(
                    outcome=data["outcome"], summary=data["summary"],
                    files_changed=data["filesChanged"],
                    verification=data["verification"],
                    provider_reference=data.get("providerReference"),
                    metadata=data.get("metadata", {}),
                )
            except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
                return WorkerResult(outcome="failed",
                                    summary=f"Codex returned an invalid result: {exc}")
