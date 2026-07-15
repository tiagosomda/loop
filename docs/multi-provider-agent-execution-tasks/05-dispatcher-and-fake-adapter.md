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
- Added deterministic dispatch ordering: Git preflight, atomic eligibility
  recheck plus run/claim transaction, routing event, adapter invocation, and
  durable finalization.
- The clean existing default-branch checkout is used with no worktree. `main`
  is the fallback; repositories whose remote default remains `master` are
  accepted, while dirty or arbitrary feature branches are rejected before
  claim or worker execution.
- Worker exceptions become normalized failed results and still finalize.
- Write-back failures are recorded on the durable run instead of erasing the
  worker outcome, and the backend contract suite passes.
