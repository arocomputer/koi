# Working in this repository

Start here before editing anything:

- Read [CONTRIBUTING.md](CONTRIBUTING.md) for the local build and test workflow.
- Read [docs/architecture.md](docs/architecture.md) before touching session ownership, transport, or the wire protocol.
- Use [docs/configuration.md](docs/configuration.md) and [docs/cli.md](docs/cli.md) for user-facing behavior.
- Run `./x help` to see the shared local/CI entry points.

## Repo expectations

- Keep the app and core code flat under `src/app/` and `src/core/`.
- Preserve public config names and wire names unless the change is explicitly a compatibility-breaking update.
- Keep `src/core/wire.zig` and `src/app/wire.swift` in sync. If you change the protocol, update both versions together.
- Work against Koid, not the user's daily Koi. The development app lives at `~/Applications/Koid.app` and is driven through `scripts/koid`.
- Do not type into the screen or click UI during Koid validation. Use the preview hooks and scripts as intended.
- App restarts preserve sessions. Use `scripts/koid stop --all` only when the dev server itself needs to be restarted.
- Keep source changes focused. Do not expose secrets, generated build output, logs, or local credentials.
- Write docs that describe implemented behavior with examples and real links.

## Validation

Match the validation to the change:

- `./x test FILTER` for app behavior
- `./x testc FILTER` for core behavior
- `./x scripts` for script and CI regressions
- `./x programs` for icon/catalog changes
- `./x check` for cross-cutting changes
- `./x bundle` for packaging or release changes
- `./x bench` only when chasing a performance question

Use the smallest relevant check. Do not repeat a passing check unless new edits or failures justify it.

## Notes for contributors and agents

- Prefer isolated, focused test cases over broad suite runs.
- Keep new headless fixture tests in the hosted filter when appropriate.
- Check visual changes in Koid instead of asserting styling constants in tests.
- Preserve shared-state fixtures as serialized, isolated test data.
- If a change affects session ownership, transport, or the wire, read the architecture guide before patching.
