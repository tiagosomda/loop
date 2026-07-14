# Task 02: Routing preferences and frontend catalog

Status: completed

## Scope

- Add nullable requested provider, model, and effort fields.
- Keep legacy model and effort fields readable during transition.
- Publish the safe enabled catalog projection for frontend consumption.
- Replace static model choices with a collapsed, data-driven routing control.
- Show only providers/models present in the projection; enabling Claude in
  configuration must make it appear without a frontend code change.

## Verification

- Backend tests cover all-null and partial overrides.
- Flutter tests cover automatic defaults and catalog-driven visibility.

## Completion evidence

- Items now store nullable `requestedProvider`, `requestedModel`, and
  `requestedEffort`; legacy model/effort values remain readable.
- The backend publishes only enabled, available, secret-free worker targets to
  `dev-loop/app/meta/targets`.
- The new-item screen defaults to Automatic and loads its optional provider,
  model, and effort choices exclusively from that projection.
- The item header now distinguishes automatic/requested routing instead of
  exposing static Claude-oriented selectors.
- Ten backend tests, Flutter static analysis, and 25 Flutter tests pass.
- Live publication was attempted but this checkout has no service-account
  credential; run `devloop targets publish` after configuring
  `DEV_LOOP_SERVICE_ACCOUNT` or `data/service-account.json`.
