# Task 01: Target catalog and probes

Status: completed

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

- Added `src/backend/config/targets.json` with enabled local-router and Codex
  targets plus a disabled Claude target.
- The Codex target advertises the verified GPT-5.6 Sol, Terra, and Luna model
  IDs with separate data-driven display labels.
- Added strict catalog validation, deterministic probes, and a secret-free
  projection in `devloop.targets`.
- Added `devloop targets list` with role and enabled filters.
- Catalog tests pass, including Codex authentication readiness,
  configuration-only Claude enablement, and safe-field filtering.
- Live `targets list --role worker --enabled-only` returned only the available
  Codex target while Claude remained disabled.
