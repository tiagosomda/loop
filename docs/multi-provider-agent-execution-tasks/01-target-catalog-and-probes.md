# Task 01: Target catalog and probes

Status: in-progress

## Scope

- Define a versioned, secret-free target configuration schema.
- Configure the local Gemma router, enabled Codex worker, disabled Claude
  worker, and a test-only fake worker.
- Probe local router and provider availability deterministically.
- Expose a safe catalog projection through the backend CLI.
- Ensure disabled targets are excluded from the enabled projection.

## Verification

- Unit tests cover schema validation, invalid combinations, probes, and
  disabled-target filtering.
- `devloop targets list` emits only safe fields and correct availability.

## Completion evidence

Pending.
