# Task 05: Dispatcher and fake adapter

Status: completed

## Scope

- Implement strict dispatch validation and deterministic lifecycle ownership.
- Use `main` and the existing checkout by default.
- Create a branch or worktree only when repository/item policy requires it.
- Add a fake adapter for lifecycle contract tests.
- Normalize worker results and failures.

## Verification

- Tests cover eligibility recheck, claim ordering, dirty checkout handling,
  invalid targets, timeout, failure, and successful finalization.

## Completion evidence

- Added a normalized adapter/result contract and side-effect-free fake adapter.
- Added deterministic dispatch ordering: eligibility and Git preflight, run
  record, claim, routing event, adapter invocation, and finalization.
- Existing clean checkout and branch are used with no worktree; dirty
  repositories are rejected before claim or worker execution.
- Worker exceptions become normalized failed results and still finalize.
- Twenty-three backend contract tests pass.
