from __future__ import annotations

from typing import Any

from .base import WorkerResult


class FakeAdapter:
    """Side-effect-free lifecycle adapter used by dispatcher contract tests."""

    def __init__(self, result: WorkerResult | None = None):
        self.result = result or WorkerResult(
            outcome="succeeded",
            summary="Fake worker completed the normalized task.",
            verification=["fake-adapter"],
            provider_reference="fake-run",
        )
        self.tasks: list[dict[str, Any]] = []

    def run(self, task: dict[str, Any]) -> WorkerResult:
        self.tasks.append(task)
        return self.result
