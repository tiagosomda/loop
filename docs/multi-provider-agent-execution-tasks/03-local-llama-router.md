# Task 03: Local llama.cpp router

Status: completed

## Scope

- Build sanitized routing context.
- Call the local OpenAI-compatible llama.cpp endpoint.
- Constrain and validate the decision schema.
- Honor overrides and policy deterministically.
- Add shadow-mode routing without claiming or dispatching an item.

## Verification

- Fixture tests cover valid decisions, malformed output, unavailable router,
  override violations, and abstention.
- A live opt-in smoke test can use `127.0.0.1:8080`.

## Completion evidence

- Added sanitized item/repository/attachment/request context construction.
- Added low-temperature, JSON-schema-constrained llama.cpp chat completion
  calls with strict post-generation validation.
- Added override, target, provider, model, effort, and unexpected-field checks.
- Added deterministic pre-inference constraint filtering, reason-code
  validation, and low-confidence abstention.
- Added local JSONL shadow recording with no item claim or dispatch side effect.
- Backend tests and the frontend verification suite pass.
- A live Gemma 3 4B smoke test selected the enabled Codex target with low
  effort and high confidence for a small README correction.
