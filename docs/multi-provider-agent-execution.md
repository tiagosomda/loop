# Multi-provider agent execution

## Status

The foreground single-worker pilot is implemented as of 2026-07-18: a
launchd-triggered deterministic orchestrator uses a local llama.cpp router,
transactionally claims an item with its run record, and dispatches either to
Codex through a trusted full-access adapter or to a bounded local Gemma worker
for small, low-risk tasks. Claude routing is implemented but its catalog target
is disabled after proving flaky in live use.

This is still an end-state design document. Bounded research/handoff bundles,
artifact reaping, resumable provider sessions, cancellation, leases,
heartbeats, and parallel dispatch remain future phases. The tracked delivery
state is in `docs/multi-provider-agent-execution-tasks/README.md`; those
features must not be inferred from the completed foreground pilot.

## Terminology

The clearest name for the feature is **multi-provider agent execution**:

- **Provider-neutral** or **agent-platform-agnostic** describes the internal
  architecture: queue lifecycle and execution policy do not depend on Claude
  Code, Codex, Gemini CLI, a local model runtime, or another platform.
- **Multi-provider support** describes the user-facing capability: dev-loop can
  select and run more than one agent provider.
- Avoid using **multi-agent** by itself. That usually means several agents
  collaborating on one task, which is separate from choosing one worker from
  several providers.

This document uses these terms:

- **scheduler** — wakes dev-loop at configured times;
- **orchestrator** — owns queue and item lifecycle;
- **router** — a small local LLM that selects provider, model, and effort;
- **dispatcher** — validates the selection and starts the chosen worker;
- **provider adapter** — translates a normalized dispatch into a provider CLI
  or SDK invocation;
- **worker** — the selected agent invocation that implements the action item;
- **target** — one allowed provider/model/location combination from the local
  capability catalog.

## Revised direction

Model and effort selection should be optional for the user. Provider selection
should also be optional once more than one provider is available.

When an `open` item reaches the front of the queue:

1. Deterministic code gathers the item and repository routing context.
2. A lightweight **local** LLM evaluates the task against a finite catalog of
   available local and cloud targets.
3. It selects the missing provider, model, and effort values while respecting
   any explicit user overrides and policy constraints.
4. It calls one validated dispatch command with that decision.
5. The dispatcher claims the item, records the resolved assignment, and starts
   the appropriate provider adapter.
6. The selected worker performs the actual implementation and returns a
   normalized result for board write-back.

The local router does **not** edit code, manage Git, claim items, post messages,
or invent shell commands. Its only responsibility is assessment followed by a
single dispatch tool call.

## Current codebase assessment

### What is already provider-neutral

The recent backend work has removed important mechanical behavior from the
scheduled agent prompt:

- `run start` marks the run, crawls repositories, logs the start, and returns
  the ordered queue.
- `run next` re-queries Firestore and returns the correct next item using
  in-progress-first and manual board order.
- `run stale <id>` mechanically detects prior branches, worktrees, commits, and
  uncommitted changes.
- `items claim` and `items status` automatically log their transitions.
- `run end` always leaves a finished-run trace and can summarize touched items.
- `items show --new` and `items fetch --new` reduce repeated context and
  attachment work on reopened items.

These commands are the beginning of the provider-neutral orchestrator. The
router and every provider adapter should call them rather than reimplementing
their behavior.

### What the current code already supports

- Firestore `model` and `effortLevel` values are nullable.
- The backend `items create` command accepts model and effort as optional
  arguments.
- The Flutter service writes `null` when the UI is set to `default`.
- Existing items without either field already deserialize correctly.

No Firestore migration is required merely to allow omitted values.

### Remaining gaps after the foreground pilot

The pilot now has nullable routing preferences, a data-driven frontend catalog,
a local schema-constrained router, transactional run/claim creation, structured
run records and routing events, trusted provider adapters, and focused backend
and frontend contract tests.

The remaining gaps are the later end-state phases:

1. Claims are atomic but are not renewable leases; there are no heartbeats.
2. Stale work is preserved and surfaced for human review, but provider sessions
   are not resumed automatically.
3. Cancellation, bounded retry, and parallel target-concurrency enforcement do
   not exist yet.
4. Optional bounded local research and manifest-owned handoff bundles are not
   implemented.
5. Provider diagnostic artifacts have no formal retention/reaper policy yet.
6. Claude is structurally implemented but intentionally disabled; Gemini and
   broader local-agent capabilities remain out of scope. The Local Gemma worker
   is deliberately limited to repository inspection, validated patches,
   network-denied checks, and deterministic Git delivery.

## Recommended end state

```text
launchd calendar trigger
                 |
                 v
        deterministic orchestrator
        run start / run next / run stale / run end
                 |
                 v
      deterministic routing-context builder
                 |
                 v
       small local routing LLM
       read context + choose from catalog
                 |
                 | one validated dispatch call
                 v
             dispatcher
      claim + run record + adapter launch
                 |
        +--------+--------+-----------+
        |                 |           |
        v                 v           v
   local worker       Codex worker  Claude/Gemini/etc.
        |                 |           |
        +--------+--------+-----------+
                 |
                 v
   normalized result + board write-back
```

The deterministic layers own every state transition. LLMs make bounded
judgments inside explicit contracts.

## Scheduler recommendation

Use the operating system scheduler as the wake-up mechanism. On this machine,
`launchd` runs the provider-neutral autonomous command at the configured
machine-local times. A separate always-on LaunchAgent supervises llama-server.

Neither Codex nor Claude schedules own orchestration. Codex is invoked only as
a worker selected by the local router, so provider selection and queue
lifecycle remain independent of any provider's scheduling product.

## User overrides: optional constraints, not resolved assignments

The item should store what the user requested; the run should store what was
actually selected.

Recommended item-level fields:

- `requestedProvider`: nullable provider override;
- `requestedModel`: nullable model override;
- `requestedEffort`: nullable normalized effort override;
- optional future policy fields such as `cloudAllowed` or `dataSensitivity`.

Recommended semantics:

1. If all requested fields are absent, the router selects the complete tuple.
2. If only some fields are supplied, they are hard constraints and the router
   fills the missing values.
3. If the complete tuple is supplied and valid, deterministic code may dispatch
   it directly without spending a local routing inference.
4. An invalid combination is rejected clearly; it is not silently rewritten.
5. A router decision is stored on a run record, not copied into the request
   fields.
6. A reopened item may be routed again unless it is resuming an existing
   in-progress run.

For backward compatibility, existing `model` and `effortLevel` fields can be
read as requested overrides during a transition. New code should avoid adding
automatic decisions to those legacy fields. A later migration may rename them
or leave them as compatibility aliases.

## Auto-first execution UI

Creating an action item should not require understanding providers, models, or
effort. The normal composer should contain only the work request, repository,
and attachments. Its default execution state is simply **Automatic**.

Add a compact, collapsed control such as **Execution preferences (optional)**
or **Customize routing**. Its closed state should say that a local router will
choose the best available worker. Opening it reveals three optional constraints:

- **Provider**: `Auto` by default; choosing one restricts the allowed targets.
- **Model**: `Auto` by default; it is filtered to models valid for the selected
  provider and may remain automatic when only a provider is chosen.
- **Effort**: `Auto` by default; it constrains the router only when selected.

The UI must allow every partial combination. For example, “use Codex, choose
the model and effort automatically” and “use high effort, choose the worker
automatically” are both valid requests. A fully specified valid tuple can be
shown as an explicit override rather than an advanced mode that every user must
learn.

The provider catalog published to the client must be a secret-free, enabled
projection of the local catalog. It replaces the current static Claude-oriented
model list. Never show an unavailable provider as a selectable default, and
never make the user repair an invalid model after changing provider; clear it
back to `Auto` or offer only compatible options.

On an item detail page, do not lead with editable provider/model/effort
selectors. Show a small summary such as **Routing: Automatic** or **Requested:
Codex · High**, with a secondary “Customize” action. Separately show the latest
run's actual assignment as **Assigned: Codex · model-name · High**. This keeps
user intent distinct from what was executed, including when a reopened item is
routed differently.

The default path must be keyboard-accessible, readable by screen readers, and
clear about privacy policy: if automatic routing may choose a cloud target,
surface the repository/item cloud policy in the optional preferences rather
than surprising the user after submission.

## Provider, model, effort, and location are distinct

Do not encode the entire decision in one free-form model string.

- **Provider/adapter** identifies the worker interface, such as `codex`,
  `claude-code`, `gemini-cli`, or `local-agent`.
- **Model** identifies a model supported by that adapter.
- **Effort** is a normalized dev-loop value such as `low`, `medium`, `high`, or
  `max`.
- **Location** is target metadata (`local` or `cloud`), not something the
  router should infer from a model name.

Provider adapters map normalized effort into the closest supported provider
control. If a provider does not support a requested effort level, that
combination should be absent from the catalog or rejected during validation.

## Target capability catalog

The router must choose from a deterministic local catalog. It must never invent
a provider, model, flag, executable, or credential name.

Each target should declare at least:

```text
targetId
adapter
location: local | cloud
allowed models
allowed effort levels
availability/enabled state
context limit or relative context tier
supports images/attachments
supports repository writes
supports network access
supports subagents or reviewer roles
supports structured events
supports resume/cancel
cost tier
privacy/data policy tags
concurrency limit
```

The catalog should live in versioned local configuration, with secrets stored
elsewhere. A deterministic probe can produce a runtime availability view by
checking executables, local model endpoints, authentication, and provider
health without exposing secret values to the router.

Example target IDs might be `local-coder-small`, `codex-standard`,
`claude-deep`, or `gemini-large-context`. These are stable dev-loop target IDs,
not direct model identifiers.

## Routing context

The router should receive a compact, sanitized packet assembled by code:

- item ID, title, full new request, and relevant prior summary;
- repository ID and deterministic metadata such as languages, project type,
  test commands, and approximate size;
- attachment names, MIME types, and sizes;
- stale-run report when recovery is involved;
- explicit user overrides;
- allowed targets after policy and availability filtering;
- cost, privacy, timeout, and cloud-use constraints;
- whether the item appears to be documentation, investigation, code, design,
  testing, deployment, or another task class;
- an optional bounded codebase-research brief tied to the exact repository
  revision and item-thread boundary from which it was produced.

The router should not need to scan the whole repository. Repository facts that
can be gathered mechanically should be cached by scripts and supplied as data.
Attachment contents should only be exposed when they are necessary for routing
and the local router supports the format.

## Local router contract

The router should be a small local model served by a configurable local runtime.
The architecture should not depend on one runtime; an adapter can support a
local HTTP endpoint or CLI as long as it produces the same structured decision.

The router should run with:

- deterministic or low-temperature generation;
- a strict output schema or tool schema;
- no repository write access;
- no network access;
- no provider credentials;
- no arbitrary shell tool;
- exactly one dispatch tool after it makes a valid decision.

It may use a separate, read-only research pass before deciding. That pass is
not a worker: it cannot change the repository, make network calls, access
credentials, claim an item, or post to the board.

Suggested structured decision:

```json
{
  "schemaVersion": 1,
  "itemId": "item-id",
  "targetId": "codex-standard",
  "provider": "codex",
  "model": "catalog-model-id",
  "effort": "medium",
  "reasonCodes": ["code-change", "moderate-scope", "tests-required"],
  "confidence": "high"
}
```

Only a short user-visible justification or reason codes should be retained. Do
not request or store hidden chain-of-thought.

### Routing criteria

The router should weigh:

- task complexity and expected duration;
- change risk and review needs;
- repository size and required context;
- attachment or vision requirements;
- need for web/network access;
- local model capability;
- provider availability and concurrency;
- cost tier and usage policy;
- privacy or cloud restrictions;
- whether a previous run must be resumed.

The router should be allowed to return `needs-human-routing` when no valid target
meets the constraints or its confidence is below a configured threshold.

## Local codebase research and worker handoff

For code tasks, a small local LLM can perform an initial, bounded exploration
before the final routing decision. This gives the eventual worker useful
navigation context without making the router responsible for implementation.

Use two explicit passes, which may use the same local runtime:

1. A deterministic repository-inspection command collects safe facts such as
   language, file tree, repository instructions, test commands, and revision.
2. A read-only local **researcher** is given that fact packet plus a limited
   task-specific file/search budget. It produces a structured brief with
   relevant files and symbols, a concise architecture summary, likely tests,
   risks, and file/line/revision citations.
3. The router receives the brief as one routing input and selects a target.
4. The selected worker receives the same brief as advisory context in its
   per-run handoff bundle.

The research pass should be conditional. Documentation-only work with obvious
scope may skip it; unfamiliar, cross-cutting, or code-changing work should use
it. Cap elapsed time, files, bytes, and output length so this is targeted
navigation rather than an expensive repository dump. The brief must label
repository-derived content as untrusted reference material, not instructions;
the worker still follows repository instructions and verifies the current code
it changes.

### Handoff bundles, not script parameters

Do not pass research text, attachments, or large prompts as command-line
arguments. The dispatcher should instead own an opaque, per-attempt bundle
outside the Git worktree:

```text
data/agent-runs/
  preflight/<preflight-id>/
    manifest.json
    routing-context.json
    research.json
    research.md
  runs/<run-id>/
    manifest.json
    resolved-assignment.json
    research.json
    research.md
    provider-events.jsonl
    result.json
```

`manifest.json` is the sole handoff contract. It records schema version,
preflight/run ID, item ID, repository ID, repository revision, relevant thread
message IDs, catalog version, content digests, timestamps, and artifact state.
The provider adapter receives only the run ID (or a fixed manifest reference)
and derives the bundle path from the trusted data root. It can mount or expose
the brief read-only to a sandboxed worker, rather than placing a generated file
inside the Git worktree or embedding its contents in shell arguments.

For a fresh item, `route prepare` creates `preflight/<preflight-id>` and gives
the router its contents. `dispatch start` verifies the item and artifact
digests, creates the run record and claim, then atomically promotes that bundle
to `runs/<run-id>`. A dispatch failure removes the preflight bundle. This keeps
the researcher usable before a claim while avoiding unowned files after a
decision.

The brief is advisory and must be invalidated if its repository revision,
thread boundary, item version, or relevant attachment digest changes. A worker
must re-check cited files before relying on them. Store only a short research
status/digest in Firestore; keep source-derived detail local and out of board
messages, prompts for unrelated workers, and Git.

### Artifact cleanup and recovery

Artifact lifecycle belongs to deterministic code, never to an LLM or provider
adapter. Use an allowlisted data root, safe opaque IDs, atomic temporary
directory-to-final-directory moves, and a manifest-owned lock. Cleanup must
never accept a path supplied by a model or recursively remove outside the known
run directory.

- Remove abandoned preflight bundles on dispatch failure and with a short TTL
  (for example, one hour) via `artifacts reap`.
- Keep an active or stale resumable run bundle only while its lease/recovery
  policy permits resumption.
- On successful finalization and board write-back, remove detailed local
  artifacts promptly and mark the run record `artifactState: deleted`; retain
  only the concise normalized result and digests.
- Keep failed/cancelled bundles for a bounded diagnostic window (for example,
  72 hours), then reap them automatically. A configured disk budget should
  trigger oldest-safe cleanup with an operational warning rather than silently
  accumulating data.
- Execute the reaper at autonomous-run start/end and as an independently
  testable command. It should report skipped locked/active bundles and leave
  enough metadata to diagnose cleanup failures.

This design prevents stale research from contaminating later runs, avoids
shell-argument limits and escaping risks, and still lets a selected worker
receive a useful local research handoff.

## Dispatcher contract

The router should call one narrow command, conceptually:

```text
devloop dispatch start <item-id> --decision <validated-json>
```

The actual CLI shape can change, but the command must:

1. Parse the decision as data, never as a shell fragment.
2. Confirm the item is still eligible and at the expected version/status.
3. Confirm requested overrides were honored.
4. Validate target, provider, model, effort, and policy against the current
   catalog.
5. Verify and promote the matching preflight handoff bundle, when present.
6. Create a run ID and resolved assignment record.
7. Claim the item immediately before worker side effects begin.
8. Write an idempotent routing event into the item thread before starting the
   worker.
9. Prepare or identify the worktree and branch.
10. Invoke the selected provider adapter with a normalized task and trusted
    run-bundle reference.
11. Capture structured events, exit state, timeout, and worker reference.
12. Finalize board write-back, status, and artifact cleanup through
    deterministic code.

The router must not be able to pass an executable path, raw flags, environment
variables, prompt template, or output parser to this command.

### Foreground first, asynchronous later

The first implementation should dispatch one worker in the foreground and wait
for its normalized result. This matches the current one-item-at-a-time runbook
and makes cleanup understandable.

The run record and dispatcher API should still model explicit states so a later
version can launch asynchronously and use `dispatch status`, `cancel`, and
`resume` without redesigning Firestore.

## Item lifecycle and routing order

Recommended order for a fresh `open` item:

```text
run next
  -> prepare bounded research bundle when task policy calls for it
  -> build routing context
  -> apply explicit overrides and policies
  -> local router fills missing selection
  -> validate decision
  -> dispatch start atomically records assignment and claims item
  -> provider worker runs
  -> deterministic finalize posts result and sets status
```

Routing may happen before the claim because it is local, bounded, and has no
side effects. The dispatcher must re-check eligibility before claiming so the
decision cannot be applied to an item that changed while routing.

For an `in-progress` item:

1. Run `run stale <id>`.
2. Load its latest unresolved run record.
3. Resume the same provider/model/effort and worktree when possible.
4. Do not send partial work through the normal fresh-item router.
5. Require an explicit recovery decision before switching providers.

This prevents a new router decision from abandoning or duplicating work.

## Provider adapter contract

Every provider adapter should implement the same conceptual interface:

```text
probe() -> availability and capabilities
prepare(normalized task, resolved assignment, worktree, policy) -> invocation
run(invocation) -> event stream
cancel(run reference) -> cancellation result
resume(run reference, normalized task) -> event stream
finalize(event stream) -> normalized worker result
```

Initial adapters may include:

- `local-agent`
- `codex`
- `claude-code`
- `gemini-cli`
- `generic-cli` for an explicitly configured command and strict result parser

Commands, SDK calls, authentication, model names, effort flags, permissions,
and output parsing remain inside the adapter. The router never sees them.

## Normalized task and result

Every worker receives the same minimum task contract:

- action item and relevant thread context;
- repository and worktree paths;
- attachments materialized only when needed;
- resolved provider, model, and effort;
- a read-only run-bundle manifest/reference, including advisory research when
  available;
- applicable repository instructions;
- lifecycle restrictions from `docs/agent-runbook.md`;
- permission, network, timeout, Git, verification, and review policies.

Every adapter returns a normalized result containing:

```text
outcome: succeeded | needs-review | failed | timed-out | cancelled
summary
files changed
verification and results
branch, commits, and pull-request URL
remaining work or user decision
attachments to publish
provider run/thread/session reference
started and finished timestamps
usage metadata when available
```

Provider output may be retained locally for debugging, but board write-back
should be concise and provider-neutral.

## Data model plan

### Action item

Candidate request fields:

```text
requestedProvider: string | null
requestedModel: string | null
requestedEffort: string | null
cloudAllowed: bool | null        # optional future policy
dataSensitivity: string | null   # optional future policy
```

Keep item summaries small. Do not store every available target or automatic
decision on the summary document.

### Run record

Add an `items/{itemId}/runs/{runId}` subcollection containing:

```text
state
router type/model/version
catalog version
resolved target/provider/model/effort/location
short reason codes and confidence
which values came from user overrides
scheduler and orchestrator version
provider run/thread/session reference
worktree, branch, commit, and PR references
timestamps and heartbeat
normalized outcome and verification summary
error classification and retry count
usage metadata when useful
research/preflight ID, input digests, repository revision, and artifact state
```

The item can retain `lastRunId` for efficient detail loading. A run record makes
automatic choices auditable and separates retries from user intent.

### Thread routing event

Routing belongs in the existing item thread as a first-class event, not as
human-looking agent text that the client later has to parse. Extend the thread
message schema with a `kind`, for example `message | routing | event`, while
preserving ordinary user/agent messages. A routing event should contain:

```text
kind: routing
runId
attempt number
state: assigned | resumed | failed-to-route
target/provider/model/effort/location
short public reason codes (optional)
createdAt and catalog version
```

The dispatcher writes the `assigned` event exactly once for a run, immediately
after validated assignment/claim and before invoking the provider. The normal
agent result is therefore naturally displayed immediately after it in the
chronological thread. The UI renders it as a compact status row, for example
“Routed to Codex · model-name · High,” rather than a chat bubble. It can link to
the run detail when one exists.

On recovery, add a `resumed` routing event for the same assignment; on a
pre-claim routing failure, add a `failed-to-route` event only when it contains
actionable, non-sensitive information. Use a deterministic event ID derived
from `runId` and event type so retries and client rebuilds cannot duplicate it.
Keep detailed provider logs and research out of the thread.

### Claim/lease evolution

The current `lastAgentRunAt` claim is sufficient while only one orchestrator
runs. Before parallel or asynchronous dispatch, add a run ID, lease owner,
lease expiration, and heartbeat so stale recovery can distinguish a dead worker
from a slow active worker.

## Frontend plan

The frontend should make automatic routing the obvious default:

1. Make the basic new-item form request/repository/attachment focused. Do not
   render provider, model, or effort until the user opens **Customize routing**.
2. Default all three values to `Auto`/`null`; save only actual choices as
   requested constraints.
3. Populate choices from a published safe catalog projection, not static Claude
   model constants; filter subsequent fields as constraints are selected.
4. Explain partial choices in plain language: “We will use Codex; the local
   router will choose the model and effort.”
5. On item detail, show concise Requested and latest Assigned summaries rather
   than permanent configuration controls. Place editing behind the same
   optional customization affordance.
6. Render `routing` thread events as an inline, non-chat status row immediately
   before the first message produced by that run. Include provider, model, and
   effort; make location visible only when policy requires it or it aids
   clarity. Never expose private reasoning, credentials, or raw prompts.
7. Keep provider/run details off the main board unless they prove useful for
   triage. The thread and item detail are the audit surfaces.

The existing nullable storage behavior means the first UI change can be small:
hide the selectors behind an optional control and continue writing `null` for
Auto. Dynamic provider-aware choices can follow after the catalog exists.

## Backend command plan

Candidate commands, subject to implementation refinement:

```text
devloop targets list                 # safe catalog + runtime availability
devloop route prepare <item-id>      # bounded local research + handoff bundle
devloop route context <item-id>      # sanitized routing packet
devloop route decide <item-id>       # invoke local router and validate output
devloop dispatch start <item-id>     # start from validated decision on stdin/file
devloop dispatch status <run-id>
devloop dispatch cancel <run-id>
devloop dispatch resume <run-id>
devloop artifacts reap               # remove expired, safely owned bundles
devloop run autonomous               # start/next/route/dispatch/finalize loop
```

`run autonomous` should compose the existing `run start`, `run next`,
`run stale`, and `run end` behavior rather than duplicate it. The Codex
scheduled task should eventually call only this command.

## Failure and fallback policy

Distinguish at least:

- local router unavailable or malformed output;
- no valid target after policy filtering;
- provider executable or local endpoint unavailable;
- authentication failure;
- permission or sandbox denial;
- provider usage/rate limit;
- worker timeout or cancellation;
- verification failure;
- stale, corrupt, or uncleanable research/handoff bundle;
- Git conflict;
- board write-back failure;
- orchestrator crash.

Recommended behavior:

- Router failure before claim leaves the item `open`, logs the infrastructure
  problem, and ends or continues according to a bounded retry policy.
- No valid target becomes `needs-human-routing` evidence without inventing a
  fallback.
- A configured deterministic fallback may be used only if it is explicitly
  enabled and valid under item/repository policy.
- Never switch providers automatically after worker side effects may exist.
- Finish and write back one item before dispatching the next.
- Repeated infrastructure failures should surface for review rather than loop
  forever.
- A stale research digest is regenerated or discarded before dispatch; it is
  never silently reused for a different repository revision or item state.

## Security model

- The local router receives no cloud credentials and no arbitrary shell.
- The dispatcher maps a validated target ID to a preconfigured adapter; the LLM
  never constructs the command.
- Provider credentials remain in each provider's intended local secret store.
- Repository scripts and dependency hooks are treated as untrusted when a
  provider credential is present in the worker environment.
- Local routing context is minimized and sanitized.
- Research bundles live only under the allowlisted local data root, use
  manifest-verified IDs and bounded retention, and are never placed in Git.
- Research is advisory context, not executable instructions; workers re-check
  the repository and do not blindly follow text extracted from it.
- Cloud routing respects explicit repository/item policy before any content is
  sent externally.
- Workers run with the least filesystem and network access that completes the
  task.
- Run records store policy and target identifiers, never secret values.
- Workers never mark items `closed`.

## Router evaluation and calibration

A local router should be evaluated like a classifier, not accepted because its
choices sound plausible.

Create a versioned fixture set of representative past items containing:

- sanitized routing input;
- acceptable targets and effort ranges;
- disallowed targets;
- required capabilities;
- expected reason codes.

Measure:

- schema-valid decision rate;
- override compliance;
- policy violation rate;
- target availability accuracy;
- agreement with reviewed human selections;
- under-routing rate for risky work;
- over-routing/cost rate for trivial work;
- fallback and abstention rate.

Log resolved assignments and outcomes so reviewed production runs can improve
the fixture set. Do not train directly on unreviewed outcomes.

## Incremental delivery plan

### Phase 1: Make user selection truly optional

- Document `model` and `effortLevel` as nullable request overrides.
- Move existing selectors behind an optional execution-override control and add
  the provider override only inside it.
- Keep legacy fields working; do not migrate automatic decisions into them.
- Add tests confirming items can be created and edited with all overrides null.

### Phase 2: Target catalog and provider probes

- Define versioned target configuration and capability schema.
- Add deterministic availability probes for local and cloud adapters.
- Publish a secret-free catalog projection for the frontend.
- Add validation tests for impossible provider/model/effort combinations.

### Phase 3: Structured run records, thread events, and dispatcher

- Add run IDs and resolved-assignment records.
- Extend the thread schema and render an idempotent inline routing event before
  each worker's message.
- Implement the narrow `dispatch start` validator.
- Add one provider adapter using a recorded/fake worker first.
- Ensure claim, worktree preparation, timeout, finalization, and failure
  write-back are deterministic.
- Add backend contract tests before invoking a real provider.

### Phase 4: Local research and handoff pilot

- Implement deterministic repository inspection and an optional read-only local
  research pass with file/time/output budgets.
- Add manifest-backed preflight/run bundles outside the worktree, digest
  invalidation, safe promotion, and deterministic reaping.
- Test success, cancellation, crash, stale-recovery, and cleanup paths without
  invoking a cloud provider.

### Phase 5: Local router pilot

- Choose a local runtime and small routing model.
- Build sanitized routing context from item, repo, attachment, policy, and
  catalog data.
- Constrain output with a strict schema/tool call.
- Start in shadow mode: record what the router would select while the existing
  agent still chooses.
- Review disagreements and calibrate fixtures and policy.
- Enable router-controlled dispatch only after shadow results are reliable.

### Phase 6: First real workers

- Add a local worker target.
- Add Codex through non-interactive execution or the Codex SDK.
- Preserve the current Claude path through a Claude adapter.
- Add Gemini only after its lifecycle, authentication, output, timeout, and
  resume behavior are understood.

### Phase 7: Autonomous run command

- Compose existing run mechanics, local routing, dispatch, monitoring, and
  finalization into `run autonomous`.
- Keep one-item-at-a-time behavior.
- Make `run end` execute through guaranteed cleanup.
- Trigger only this entry point from the local `launchd` calendar agent.
- Review several scheduled runs before expanding permissions or concurrency.

### Phase 8: Resumption and optional concurrency

- Add leases and heartbeats.
- Resume existing resolved assignments for stale work.
- Add cancellation and bounded retries.
- Consider parallel dispatch only after item/run isolation is proven.

## File-by-file implementation map

The pilot uses these touch points; the research/reaping and lease/resume pieces
remain future additions:

- `src/backend/devloop/run.py` — compose the autonomous run without replacing
  existing queue/stale/end mechanics;
- `src/backend/devloop/items.py` — request overrides, run references, and
  transactional claim/lease support;
- `src/backend/devloop.py` — target, route, dispatch, and autonomous commands;
- new backend modules for catalog, router, dispatcher, run records, and provider
  adapters; add a deterministic research/bundle manager and artifact reaper;
- `data/agent-runs/` — ignored, manifest-owned ephemeral research and provider
  handoff bundles; no agent writes arbitrary paths here;
- `src/frontend/lib/models/models.dart` — requested and resolved execution data;
- `src/frontend/lib/screens/new_item_sheet.dart` — optional override UI;
- `src/frontend/lib/screens/item_screen.dart` — requested versus assigned
  execution display and inline routing-event rendering;
- `src/frontend/lib/services/board_service.dart` — nullable overrides, catalog
  projection, and run-record reads;
- `docs/agent-runbook.md` — worker contract after deterministic orchestration
  owns routing and finalization;
- provider permission/configuration files — allow only the new narrow entry
  points required by each role.

## Acceptance criteria

The foreground router-controlled pilot is ready when:

- users can create items with provider, model, and effort all omitted;
- partial user overrides are honored exactly;
- the local router can only choose valid enabled catalog entries;
- router output is schema-valid or safely rejected before claim;
- the dispatcher cannot execute an arbitrary command supplied by the router;
- resolved provider/model/effort are recorded per run and remain distinct from
  user requests;
- each dispatched run produces one durable, compact routing event in the item
  thread before its worker message;
- fresh items route before claim and are revalidated at dispatch;
- in-progress items are never silently rerouted and do not block later work;
- a fake adapter, Codex, and the bounded Local Gemma worker pass the lifecycle
  contract, while the disabled Claude adapter passes its mocked contract;
- timeout, authentication, sandbox, rate-limit, and write-back failures leave
  useful recoverable state;
- one item is finalized before the next is dispatched;
- scheduled local runs invoke the provider-neutral entry point;
- credentials are absent from Firestore, attached logs, prompts, and Git;
- workers never mark an item `closed`.

Research manifests/reaping, automatic resumption, cancellation, leases,
heartbeats, bounded retries, and parallelism are acceptance criteria for Tasks
9–10, not for the foreground pilot.

## Open decisions

1. Should Local Gemma expand beyond small validated patches, and what evidence
   would justify broader tools?
2. Should a fully specified valid user override bypass local inference, or
   should the router always confirm it?
3. What normalized effort vocabulary should dev-loop expose?
4. Should cloud use default to allowed, denied, or repository-specific?
5. Which repository facts should the crawl cache for routing?
6. Is the current `medium` confidence threshold correct after shadow data?
7. What deterministic fallback, if any, is acceptable when the router is down?
8. How long should routing decisions, run records, raw logs, and worktrees be
   retained?
9. Should the router choose whether a separate reviewer worker is required, or
   should reviewer policy be derived deterministically from effort/risk?
10. Should launchd failure notifications be mirrored somewhere beyond the
    frontend health summary and local logs?
11. Which task classes require a research pass, and what file/time/token budget
    is worthwhile for each?
12. What retention window balances safe debugging of failed runs with the goal
    of leaving no stale local research behind?

## First implementation decision

The implemented pilot makes provider/model/effort optional, validates a local
catalog, routes with Gemma through llama.cpp, dispatches Codex with full access
inside a trusted adapter, can dispatch small low-risk work to a bounded local
Gemma adapter, and uses launchd for both model supervision and calendar
orchestration. Claude remains data-disabled until explicitly enabled.
