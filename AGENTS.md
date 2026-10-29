# Working in this repository

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the build, test and Koid workflow.
`./x help` lists the shared local/CI checks; `./x check` runs the full suite
and verifies a release bundle without installing it.
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
- Before finishing a code change, run `scripts/koid test` and
  `scripts/bundle.sh`. Check visual changes in Koid.
- Keep docs focused on implemented behavior, with working examples and
  relative links. Update affected docs and comments with the code.
