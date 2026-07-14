# Multi-provider agent execution tasks

This folder turns `docs/multi-provider-agent-execution.md` into small,
verifiable implementation slices. Work proceeds on `main`, one completed and
tested commit at a time.

## Status vocabulary

- `pending` — not started;
- `in-progress` — the current implementation slice;
- `completed` — acceptance checks passed and the slice was committed.

## Execution order

1. [Target catalog and probes](01-target-catalog-and-probes.md)
2. [Routing preferences and frontend catalog](02-routing-preferences-and-frontend-catalog.md)
3. [Local llama.cpp router](03-local-llama-router.md)
4. [Run records and routing events](04-run-records-and-routing-events.md)
5. [Dispatcher and fake adapter](05-dispatcher-and-fake-adapter.md)
6. [Codex and Claude adapters](06-provider-adapters.md)
7. [Autonomous orchestration and launchd](07-autonomous-orchestration-and-launchd.md)
8. [Integration, operations, and rollout](08-integration-operations-and-rollout.md)

Provider availability in the frontend is always data-driven. The UI consumes
the enabled safe catalog projection; it contains no hard-coded Codex, Claude,
or model visibility rules.
