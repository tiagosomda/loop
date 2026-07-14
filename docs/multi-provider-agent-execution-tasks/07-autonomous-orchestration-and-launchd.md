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
- Added an advisory single-instance lock and explicit stale-item stop rather
  than silently rerouting an in-progress item.
- Added separate llama-server supervision and calendar orchestrator
  LaunchAgents for the five configured local times.
- Thirty backend tests pass, including idle, failure-finally, dispatch, and
  overlapping-run behavior.
- Both plist files pass `plutil -lint`.
- LaunchAgents remain unloaded until the manual port-8080 server is stopped and
  a Firebase service-account credential is configured.
