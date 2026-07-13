# Multi-provider agent execution

## Status

Planning document only. Nothing in this document is implemented yet.

## Terminology

The feature should be described as **multi-provider agent execution**:

- **Provider-neutral** or **agent-platform-agnostic** describes the internal
  architecture: the board lifecycle and execution contract do not depend on
  Claude Code, Codex, Gemini CLI, or another agent platform.
- **Multi-provider support** describes the user-facing capability: dev-loop can
  run work with more than one agent provider.
- Avoid using **multi-agent** by itself. That term commonly means several agents
  collaborating on one task, which is a separate capability that an individual
  provider may or may not support.

This document uses **provider** for an agent platform and **worker** for one
provider invocation that performs an action item.

## Summary

dev-loop already has most of the provider-neutral pieces:

- Firestore is the action-item queue and source of truth.
- The backend CLI lists, claims, reads, updates, and posts results to items.
- `docs/agent-runbook.md` defines the lifecycle every worker must follow.
- Repositories and credentials are local concerns rather than being embedded in
  the board.
- The user retains the final decision to close an item.

The remaining work is to separate **orchestration** from **agent execution**.
The orchestrator should own the lifecycle, safety rules, worktree management,
and write-back behavior. Small provider adapters should only translate a
normalized task into a Claude, Codex, Gemini, or other agent invocation and
translate its result back into a normalized run result.

## Recommendation: begin with a Codex scheduled task

The first additional provider should be Codex, triggered through a **Codex
scheduled task**.

This is the best initial path because it can:

- run against a local project or an isolated Git worktree;
- run a durable prompt on a custom schedule;
- use the existing `docs/agent-runbook.md` and backend CLI;
- expose runs for review in the desktop app;
- avoid building another scheduler before the provider boundary is understood.

The current five-times-per-day cadence can be represented as a custom scheduled
task. Local scheduled work requires the computer to remain powered on, the
desktop app to be running, and the project to remain available at its configured
path.

The scheduled task prompt should be deliberately thin. It should tell Codex to
enter the dev-loop project, follow `docs/agent-runbook.md`, use the backend CLI
for all board state transitions, and leave the final `closed` decision to the
user. Durable workflow detail should remain in the repository rather than being
duplicated inside the scheduled prompt.

OpenAI's current documentation for this capability is:

- [Scheduled tasks](https://developers.openai.com/codex/app/automations)
- [Non-interactive Codex execution](https://developers.openai.com/codex/noninteractive)
- [Codex SDK](https://developers.openai.com/codex/sdk)

### Why this is a starting point, not the final abstraction

A Codex scheduled task is naturally Codex-specific. The long-term architecture
should therefore keep the **scheduler** and **worker provider** as separate
concepts. The initial implementation may use Codex for both, while a later
provider-neutral runner can be triggered by an operating-system scheduler, CI,
or another scheduling platform and select Claude, Codex, Gemini, or another
worker per item.

## Goals

- Preserve the existing claim, execute, report, and review lifecycle.
- Allow a default provider for the installation and an optional provider choice
  per action item.
- Keep model and effort hints independent from provider selection.
- Make provider failures observable without leaving items silently stuck.
- Support resumable work without accidentally running the same side effects
  twice.
- Keep work isolated from the user's active checkout where practical.
- Make adding a provider a small adapter task rather than an orchestration
  rewrite.
- Continue requiring useful board write-back for every attempted item.

## Non-goals

- Running several providers competitively on every action item.
- Automatically handing partially completed work to another provider.
- Normalizing every provider-specific feature into a lowest-common-denominator
  API.
- Removing human review or allowing a worker to mark an item `closed`.
- Storing provider credentials, prompts containing secrets, or raw environment
  data in Firestore.
- Building a hosted multi-tenant agent service.

## Proposed architecture

### 1. Scheduler

The scheduler starts a dev-loop run at the configured times. It should know
**when** to run, but not how a specific provider executes an item.

Possible scheduler implementations:

1. Codex scheduled task — recommended for the first Codex pilot.
2. Claude Code scheduled task — current behavior.
3. Local `launchd`/cron/system scheduler — provider-neutral long-term option.
4. CI or an always-on runner — useful only when all required repositories and
   credentials are available in that environment.

Only one top-level run should operate on the queue at a time unless explicit
concurrency and leases are added later.

### 2. Orchestrator

The orchestrator owns behavior shared by every provider:

1. Mark the schedule run timestamp and crawl repositories.
2. List `open` and `in-progress` items.
3. Reconcile stale `in-progress` work.
4. Select an item and resolve its repository.
5. Claim the item before execution.
6. Prepare an isolated worktree or a deliberately selected checkout.
7. Build the normalized task context.
8. Select and invoke a provider adapter.
9. Collect the result, verification evidence, branch, commit, and PR details.
10. Post a useful message to the board.
11. Set `needs-review` or `completed`, or record a clearly explained failure.

The orchestrator must attempt write-back in a `finally`-style cleanup path so a
provider crash or timeout does not lose the run outcome.

### 3. Provider adapter

Each provider adapter should implement the same conceptual contract:

```text
prepare(normalized task, repository, worktree, policy) -> invocation
run(invocation) -> event stream
cancel(run) -> cancellation result
resume(provider run reference, normalized task) -> event stream
finalize(event stream) -> normalized run result
```

An adapter may expose additional capabilities, but the orchestrator should only
depend on declared capabilities such as:

- supports structured event output;
- supports resuming a provider thread or session;
- supports a requested model or effort level;
- supports the required filesystem and network access;
- supports provider-native subagents;
- supports cancellation and a hard timeout.

Initial adapters could include:

- `claude-code`
- `codex`
- `gemini-cli`
- `generic-cli` for an explicitly configured command and result parser

Provider commands, flags, output formats, and authentication must remain inside
their adapter. They should not leak into the Firestore lifecycle or frontend.

### 4. Normalized task

Every adapter should receive the same minimum context:

- action-item ID, title, status, and full message thread;
- repository ID, local path, remote, and default branch;
- worktree path and branch naming expectations;
- attachments materialized as local paths when needed;
- model and effort hints;
- applicable repository instructions such as `AGENTS.md` or equivalent;
- the dev-loop runbook and lifecycle restrictions;
- permission policy, network policy, time limit, and verification expectations.

The task should state invariants explicitly:

- claim has already happened;
- do not mark the item `closed`;
- do not expose credentials;
- preserve unrelated user changes;
- verify work proportionally to risk;
- return enough structured information for board write-back.

### 5. Normalized run result

At minimum, every worker should return:

```text
provider
provider run/thread/session reference, when available
outcome: succeeded | needs-review | failed | timed-out | cancelled
summary
files changed
verification performed and results
branch, commits, and pull-request URL
remaining work or requested user decision
attachments to publish
started and finished timestamps
```

Raw provider logs may be retained locally for debugging, but the board message
should be a concise provider-neutral summary.

## Data model changes to consider

These fields are candidates, not final schema:

### Action-item summary

- `agentProvider`: optional requested provider (`codex`, `claude-code`,
  `gemini-cli`, or `default`)
- `model`: provider-specific model hint, as today
- `effortLevel`: provider-specific effort hint, as today
- `lastRunId`: reference to the most recent execution attempt

Provider selection should not be stored in `model`; choosing a platform and
choosing one of that platform's models are different decisions.

### Run record

Consider an `items/{itemId}/runs/{runId}` subcollection containing:

- provider and scheduler identifiers;
- provider run/thread/session reference;
- state and timestamps;
- worktree, branch, commit, and PR references;
- normalized outcome and verification summary;
- timeout or error classification;
- usage metadata when the provider exposes it and storing it is useful;
- the orchestrator version or commit that launched the run.

A separate run record avoids inflating the item summary and makes retries and
provider comparisons auditable.

## Provider selection policy

Provider choice should be deterministic:

1. Use an explicit `agentProvider` on the item when present.
2. Otherwise use the installation's configured default provider.
3. Validate that the provider is available and supports the requested policy.
4. If unavailable, do not silently switch providers after work may have begun.
   Post a clear board message or leave the item open for the next run.

Automatic fallback is safe only before the item has produced side effects, or
after the orchestrator can prove the failed attempt made no changes. Resuming a
partially completed run with the same provider is preferable to handing an
unknown working tree to another provider.

## Worktrees and concurrency

- Default to one worktree per item or run.
- Use predictable metadata to associate an item, run, provider, branch, and
  worktree.
- Check for an existing worktree before treating stale `in-progress` work as
  fresh.
- Do not let two providers work on the same item concurrently by default.
- Add a lease or run ID to claims before enabling parallel queue processing.
- Archive or remove completed worktrees according to a defined retention
  policy; do not let scheduled runs accumulate them indefinitely.

## Failure and recovery behavior

The orchestrator should distinguish:

- provider command unavailable;
- authentication failure;
- permission or sandbox denial;
- provider rate or usage limit;
- agent timeout;
- verification failure;
- Git conflict;
- board write-back failure;
- unexpected process crash.

Every failure should preserve enough local and board state for the next run to
decide whether to resume, retry, or request user input. Retry limits should be
bounded, and repeated failures should become `needs-review` rather than cycling
forever.

## Security model

- Run workers with the least filesystem and network access that still permits
  the requested task.
- Prefer isolated worktrees and controlled runner environments.
- Keep Firebase, GitHub/GitLab, and provider credentials in the local secret
  mechanisms intended for each tool.
- Never place API keys or service-account contents in item threads, prompts,
  logs attached to the board, or committed configuration.
- Treat repository-controlled build scripts and dependency hooks as untrusted
  when exposing provider credentials.
- Require explicit configuration before allowing unrestricted host access.
- Record the effective provider and permission policy for each run.

For the Codex scheduled-task pilot, review the first several runs manually and
start with the narrowest unattended permissions that can access the selected
project, backend CLI, repositories, and required network services.

## Incremental delivery plan

### Phase 1: Codex scheduled-task pilot

- Create and manually test a durable Codex task prompt that follows the existing
  runbook.
- Run it against one low-risk action item in an isolated worktree.
- Confirm claiming, repository selection, verification, board write-back, and
  final status behavior.
- Configure the existing five-times-per-day schedule only after the manual run
  is reviewable.
- Observe several scheduled runs before expanding permissions or scope.

This phase may use Codex directly without first building a generic adapter, but
all lessons should be captured as requirements for the provider boundary.

### Phase 2: Extract provider-neutral orchestration

- Move queue lifecycle and cleanup behavior into one orchestrator entry point.
- Define normalized task and result structures.
- Make scheduler invocation independent from provider invocation.
- Add run IDs and structured local logs.
- Preserve the existing Claude workflow through a Claude adapter.

### Phase 3: Codex adapter

- Invoke Codex through non-interactive execution or the Codex SDK.
- Prefer structured events over parsing human-readable terminal output.
- Map model, effort, sandbox, timeout, cancellation, and resumption behavior.
- Store only useful normalized metadata and references.

### Phase 4: Additional providers

- Add Gemini and other providers one at a time.
- Document each provider's capability and authentication requirements.
- Add contract tests using recorded provider fixtures where practical.
- Do not add a provider until failure and timeout behavior are understood.

### Phase 5: Frontend controls and observability

- Add a provider selector to new/edit item flows.
- Show the effective provider and latest run outcome on item details.
- Show run history without loading it on the main board.
- Add filters only if provider selection becomes operationally useful.

## Acceptance criteria

Multi-provider execution is ready when:

- the same action-item lifecycle passes against at least two provider adapters;
- provider selection is independent from model selection;
- an unavailable provider fails clearly without silent fallback;
- timeout, crash, and authentication failures produce useful board state;
- stale `in-progress` work can be reconciled with its run and worktree;
- workers never mark items `closed`;
- credentials are absent from Firestore, attached logs, and Git history;
- scheduled Codex runs are visible and reviewable;
- the existing Claude path remains functional during migration;
- documentation explains how to add and validate another provider.

## Open decisions

1. Should provider choice be visible on the board summary or only item detail?
2. Should the default provider be global, per repository, or both?
3. Should scheduled runs use one long-lived provider thread or a fresh thread
   per top-level run?
4. How long should run records, raw logs, and completed worktrees be retained?
5. Should providers be allowed to open pull requests automatically, or should
   that be a per-repository policy?
6. What exact conditions permit an automatic retry?
7. When provider-native subagents are used, should only the top-level provider
   be recorded, or should child-agent activity also be summarized?
8. Should the long-term scheduler remain a Codex scheduled task or become a
   fully provider-neutral local service once multiple adapters exist?

## First implementation decision

When implementation begins, start with the Codex scheduled-task pilot and one
manually selected, low-risk item. Do not begin by changing the frontend or
generalizing the entire backend. Use the pilot to validate the runbook as a
provider contract, then extract only the abstractions demonstrated to be
necessary.
