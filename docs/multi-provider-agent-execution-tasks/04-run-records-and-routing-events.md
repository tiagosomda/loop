# Task 04: Run records and routing events

Status: completed

## Scope

- Store resolved assignments per run, separate from item requests.
- Add idempotent structured routing events to item threads.
- Render routing events as status rows rather than chat messages.
- Show requested versus assigned routing on item detail.

## Verification

- Backend tests cover idempotency and request/assignment separation.
- Flutter tests cover routing-event and assignment rendering.

## Completion evidence

- Added per-item run assignment records and `lastRunId` references without
  mutating item request fields.
- Added transactionally idempotent routing event documents with deterministic
  IDs derived from run and state.
- Added Flutter run/event models, latest-assignment display, and compact
  routing timeline rows.
- Deterministic event identity and frontend assignment/event labels have
  regression coverage; all backend and frontend suites pass.
