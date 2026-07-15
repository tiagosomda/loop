from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol


COMPLETION_POLICY = [
    (
        "Return `succeeded` when the requested work is complete and you are "
        "confident in it after proportionate verification. This tells the "
        "dispatcher to mark the action item completed."
    ),
    (
        "Return `needs-review` only when a specific user decision or action is "
        "required before the request can be considered complete. Do not use it "
        "merely to invite optional review of completed work."
    ),
    (
        "Before returning `succeeded`, commit and push any repository changes. "
        "Report unavailable verification honestly, but do not require perfect "
        "certainty when the completed work is otherwise well supported."
    ),
]


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
