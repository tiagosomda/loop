from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol


@dataclass
class WorkerResult:
    outcome: str
    summary: str
    files_changed: list[str] = field(default_factory=list)
    verification: list[str] = field(default_factory=list)
    provider_reference: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "outcome": self.outcome,
            "summary": self.summary,
            "filesChanged": self.files_changed,
            "verification": self.verification,
            "providerReference": self.provider_reference,
            "metadata": self.metadata,
        }


class ProviderAdapter(Protocol):
    def run(self, task: dict[str, Any]) -> WorkerResult: ...
