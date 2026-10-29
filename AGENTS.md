# Working in this repository

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the build, test and Koid workflow.
`./x help` lists the shared local/CI checks. Use the smallest relevant check
while developing; `./x check` runs correctness checks without packaging.
The [architecture guide](docs/architecture.md) describes session ownership,
transport and storage; [configuration](docs/configuration.md) and
[CLI](docs/cli.md) are the user-facing references.

- Preserve unrelated changes. Never expose secrets or commit generated
  dependencies, build output, logs or local credentials.
- Keep source files flat and lowercase under `src/app/` and `src/core/`.
  Follow existing language conventions; preserve public config and wire names.
- Keep `src/core/wire.zig` and `src/app/wire.swift` compatible. Update both
  protocol versions when making an incompatible wire change.
- Work against **Koid**, never the user's daily Koi. It is installed at
  `~/Applications/Koid.app`. Drive it through `scripts/koid` and its preview
  hooks; do not send keystrokes or clicks to the screen.
- App restarts preserve sessions. `scripts/koid stop --all` ends development
  shells; use it only when the server itself needs restarting.
- Match validation to the change. Use `./x test FILTER` for app behavior,
  `./x test-core FILTER` for core behavior, `./x scripts` for build/CI scripts,
  and `./x programs` for catalog edits. These commands isolate their fixtures.
  Run the full suite for cross-cutting changes; run `./x bundle` for packaging,
  toolchain or release changes. Use `./x bench` when investigating performance.
  Do not repeat passing checks unless new edits or failures justify it.
  Check visual changes in Koid; avoid tests that pin styling constants.
- Keep new headless suites in the hosted filter when appropriate; compilation
  alone does not execute a test. Keep shared-state fixtures serialized.
- Keep docs focused on implemented behavior, with working examples and
  relative links. Update affected docs and comments with the code.
