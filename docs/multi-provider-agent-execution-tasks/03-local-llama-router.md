# Task 03: Local llama.cpp router

Status: pending

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

Pending.
