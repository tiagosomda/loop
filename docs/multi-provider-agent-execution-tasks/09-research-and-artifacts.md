# Task 09: Bounded research and artifact lifecycle

Status: pending

## Scope

- Add the optional read-only local research pass described in the design.
- Create manifest-owned, digest- and revision-scoped handoff bundles.
- Verify and promote preflight bundles at claim time.
- Add deterministic retention and `artifacts reap` cleanup.
- Keep research and detailed provider logs out of board threads and Git.

## Verification

- Tests cover manifest validation, stale revision/thread rejection, ownership,
  success cleanup, failed-run retention, and expired artifact reaping.
- A pilot demonstrates a bounded research handoff without repository writes.

## Completion evidence

Not started. Provider event logs are currently retained under the trusted run
directory for diagnostics; a reaper and formal manifest contract do not yet
exist.
