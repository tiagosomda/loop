# Task 07: Autonomous orchestration and launchd

Status: in-progress

## Scope

- Compose existing run commands into `run autonomous`.
- Process one item at a time with a single-instance lock.
- Add a launchd-supervised llama-server LaunchAgent.
- Add a separate calendar-triggered orchestrator LaunchAgent.
- Publish safe schedule, health, and last-run state for the frontend.

## Verification

- Tests cover idle runs, overlapping invocation, router downtime, worker
  failure, and guaranteed run-end logging.
- Validate generated plists with `plutil`.

## Completion evidence

Pending.
