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
- Provider JSONL is retained in a trusted per-run directory, including partial
  timeout output, and the provider thread ID is recorded when available.
- Worker prompts explicitly prohibit board credentials, board mutation, and
  lifecycle ownership, and require verified changes to be committed and pushed
  before the worker returns.
- The trusted dispatcher downloads board attachments before claim; image paths
  are passed to Codex with `--image`, while credentials remain outside the
  worker prompt and repository.
- Full access is hardcoded with
  `--dangerously-bypass-approvals-and-sandbox` inside the trusted adapter.
- Added a Claude Code adapter boundary while keeping `claude-standard`
  disabled; it was not live-tested or invoked.
- Gemini remains out of scope.
- Mocked Codex and Claude argument, structured-result, and timeout contracts
  pass. Claude remains disabled and was not live-invoked.
- An isolated real Codex smoke run succeeded with no file changes, preserved
  seven provider events, and captured its provider thread reference.
- Isolated CLI probes succeeded for `gpt-5.6-sol`, `gpt-5.6-terra`, and
  `gpt-5.6-luna` with the authenticated macOS user.
