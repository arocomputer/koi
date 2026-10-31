# Contributing to Koi

Koi is developed with Koid, not the daily app. Keep development shells isolated so local experiments do not disturb the terminal you use every day.

Before changing anything important, read:

- [docs/architecture.md](docs/architecture.md) for server ownership, transport, and wire behavior
- [docs/cli.md](docs/cli.md) for user-facing CLI semantics
- [docs/configuration.md](docs/configuration.md) for settings and options

## Prerequisites

Koi targets Apple silicon Macs running macOS 26+.

Required tools:

- Xcode with Swift 6.2+
- Zig 0.17.0
- Python 3
- Git

The locally verified toolchain is Xcode 27.1 / Swift 6.4 and Zig 0.17.0. The repo also documents the hosted CI versions and explicit `DEVELOPER_DIR` handling, so keep Xcode selection intentional.

## Local workflow

From the repo root:

```sh
./x help
./x check
./x test PaletteSearchTests
./x test-core watcher
scripts/koid build
scripts/koid run
```

`./x` is the project entry point. `./x help` lists available commands. `./x test` delegates to the Koid-backed test runner, while `./x bundle` covers packaging and release validation.

Useful commands:

```sh
./x scripts      # script and CI regressions
./x programs     # catalog and icon validation
./x bench        # optional performance checks
./x bundle       # packaging and release checks
```

Do not run broad suites when a focused check will answer the question. Match validation to the change.

## Development rules

- Keep source flat under `src/app/` and `src/core/`.
- Preserve existing config and wire names unless the change is an intentional compatibility break.
- Keep `src/core/wire.zig` and `src/app/wire.swift` synchronized.
- Prefer Koid for interaction, not the user's daily Koi build.
- Keep tests isolated and avoid touching real user configuration or existing sessions.
- Add a regression for meaningful behavior changes.
- Check visual changes in Koid rather than pinning styling constants in tests.

## Testing guide

Use the smallest relevant check:

- app behavior: `./x test FILTER`
- core behavior: `./x test-core FILTER`
- script/CI changes: `./x scripts`
- catalog or artwork changes: `./x programs`
- broad correctness pass: `./x check`
- packaging/toolchain changes: `./x bundle`

Cross-cutting work should still use the focused suite first, and full validation after targeted tests pass.

## Documentation

Docs should explain what is implemented, how it works, and how to use it. Keep examples concrete and make sure links are real and relevant.

When you change behavior, update the docs that explain it. This includes user-facing docs, developer architecture notes, and CLI behavior if the change affects scripts or tools.

## Project structure

- `src/app/` — Swift app UI, state, settings, and app-side connections
- `src/core/` — Zig server, PTY lifecycle, transport, and protocol logic
- `docs/` — architecture, configuration, CLI, and developer references
- `tests/` — app and core regression coverage
- `scripts/` — local build, tooling, and Koid helpers

## CI and release notes

The repo uses shared local/CI commands, not ad hoc scripts. In CI, changes are filtered by scope and different jobs run for core, Swift, packaging, and catalog validation.

For dependency or release-related work, review the CI and bundling docs before changing build or package behavior.

## Detailed development guidance

The [development reference](docs/development.md) retains fixture isolation,
preview commands, protocol and rendering rules, and dependency/release guidance.
Use `./x mutate` (core) or `./x mutate --app` after changing security boundaries,
limits or lifecycle rules. App tests require macOS; Linux can run `./x scripts`,
`./x programs` and `./x test-core` with the pinned Zig toolchain.

For catalog changes, see [Program icons](docs/development.md#program-icons).
