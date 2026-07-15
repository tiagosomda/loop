# Task 07: Autonomous orchestration and launchd

Status: completed

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

- Added `run autonomous`, composing existing run start/next/end mechanics with
  local routing and trusted adapter dispatch.
- Added an advisory single-instance lock. Stale in-progress work is inspected,
  preserved, surfaced for review, and moved to `needs-review` so later open
  work is not permanently blocked; it is never silently rerouted.
- Added separate llama-server supervision and calendar orchestrator
  LaunchAgents for the six configured machine-local times.
- Router confidence abstentions use the catalog's deterministic Codex
  `gpt-5.6-sol`/high fallback when that target remains available and compatible
  with explicit routing constraints. Otherwise the item is paused for review.
- A worker `succeeded` outcome now completes the item after Git postflight has
  confirmed any repository changes are committed and pushed. Only an explicit
  `needs-review` result (including incomplete Git delivery) uses that status.
- Provider prompts and the structured-result schema define `succeeded` as the
  normal outcome for complete, confidently verified work. `needs-review` is
  reserved for a concrete user decision or action, not optional review.
- Run-end logging now occurs even when bootstrap fails. Completion publishes
  safe router/provider health and outcome state for the frontend.
- Backend tests cover idle, bootstrap failure, failure-finally, stale queue
  continuation, dispatch, and overlapping-run behavior.
- Both plist files pass `plutil -lint`.
- The llama-server LaunchAgent is loaded, healthy, and proven to restart after
  termination. The orchestrator LaunchAgent still requires a Firebase
  service-account credential before it can be safely loaded.
