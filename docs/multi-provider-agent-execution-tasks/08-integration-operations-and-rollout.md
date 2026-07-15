# Task 08: Integration, operations, and rollout

Status: in-progress

## Scope

- Add end-to-end tests across catalog, router, dispatcher, and write-back.
- Document installation, launchd loading, logs, manual triggering, and recovery.
- Run the router in shadow mode and record calibration results.
- Enable real scheduled dispatch only after explicit rollout verification.

## Verification

- Backend and Flutter test suites pass.
- Manual health, shadow-routing, and Codex adapter checks are recorded.
- Operational rollback steps are documented.

## Completion evidence

In progress:

- Fifty-two backend tests pass.
- Flutter analysis reports no issues and all 30 Flutter tests pass.
- Both LaunchAgent plists pass `plutil -lint`.
- The llama-server LaunchAgent is installed and healthy. A controlled
  termination replaced PID 20835 with PID 20873 and returned healthy again,
  proving unconditional restart supervision.
- A real isolated Codex full-access adapter smoke run succeeded without file
  changes; its JSONL events and provider reference were captured.
- Operational install, inspection, manual-run, disable, and rollback commands
  are documented in `ops/launchd/README.md`.
- The orchestrator LaunchAgent remains intentionally unloaded because no
  Firebase service-account credential is currently available to this checkout.
