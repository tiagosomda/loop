# Task 06: Codex and Claude adapters

Status: completed

## Scope

- Implement Codex non-interactive execution with Full access fixed inside the
  trusted adapter.
- Pass prompts through stdin and capture structured JSONL/result output.
- Implement the Claude adapter contract but keep its target disabled.
- Do not add Gemini in this phase.

## Verification

- Contract tests mock provider processes and verify trusted argument mapping,
  timeout, result parsing, and disabled Claude behavior.
- A manual Codex smoke test is explicitly opt-in.

## Completion evidence

- Added a Codex adapter using non-interactive execution, stdin task delivery,
  JSONL events, a strict final-result schema, and normalized timeouts/failures.
- Full access is hardcoded with
  `--dangerously-bypass-approvals-and-sandbox` inside the trusted adapter.
- Added a Claude Code adapter boundary while keeping `claude-standard`
  disabled; it was not live-tested or invoked.
- Gemini remains out of scope.
- Twenty-six backend tests pass, including Codex argument and result contracts.
