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
  LaunchAgents for the five configured local times.
- Run-end logging now occurs even when bootstrap fails. Completion publishes
  safe router/provider health and outcome state for the frontend.
- Backend tests cover idle, bootstrap failure, failure-finally, stale queue
  continuation, dispatch, and overlapping-run behavior.
- Both plist files pass `plutil -lint`.
- The llama-server LaunchAgent is loaded, healthy, and proven to restart after
  termination. The orchestrator LaunchAgent still requires a Firebase
  service-account credential before it can be safely loaded.
