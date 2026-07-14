# Task 10: Resumption, leases, and concurrency

Status: pending

## Scope

- Add provider session resume and explicit cancellation commands.
- Record resumed routing events against the original assignment.
- Add leases, lease expiry, heartbeats, and bounded retry policy.
- Enforce catalog concurrency limits before enabling parallel dispatch.
- Distinguish dead workers from active long-running workers during recovery.

## Verification

- Tests cover resume, cancellation, lost heartbeat, lease takeover, retry
  exhaustion, and per-target concurrency enforcement.
- Parallel dispatch remains disabled until recovery behavior is proven.

## Completion evidence

Not started. The current pilot deliberately serializes work with one local
process lock. A stale in-progress item is preserved, moved to `needs-review`,
and surfaced with evidence; it is not silently rerouted or resumed.
