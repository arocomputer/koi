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

use the scripts when comparing the identity of built and running servers.

Builds use a signing identity named `Koi Dev` when present, otherwise an ad
hoc signature. `scripts/signing-cert.sh` optionally creates that identity in the
login keychain; macOS may request keychain access and trust confirmation.

## Exercise Koid

Drive sessions through the CLI and use preview hooks for floating controls.
Do not send keystrokes or clicks to the screen when automating development.

```sh
scripts/koid koi ls
scripts/koid koi info --json
scripts/koid koi new --cwd "$PWD"
scripts/koid koi send 1 'echo hello\n'
scripts/koid koi capture 1
scripts/koid palette 'codex waiting'
scripts/koid palette
scripts/koid palette run browse_work
scripts/koid popup machines
scripts/koid popup hint:toggle_sidebar
scripts/koid shot build/preview.png
```

Other popup previews are `tab`, `group` and `shortcut`; the shortcut recorder
requires Settings → Shortcuts to be visible. `popup dismiss` dismisses the
popup preview. The `machines` preview uses the compact picker in Top placement.
Hover hints use `hint:` followed by an action ID, such as
`new_split` or `close_pane`, and keep the normal hover delay.

`palette run ID [VALUE]` invokes a catalog action or submits a prompt. For
example, `palette run rename_tab Review` names the selected tab. Use
`palette inspect /absolute/path/state.json [QUERY]` to read selection,
catalog matches, window visibility, pane connection/frame counters and
presentation state while waiting for asynchronous work.
These hooks are compiled only into Koid. Window capture can be unavailable
in some desktop sessions; offscreen view rendering can still check layouts.

`scripts/koid run` restarts only the app; `scripts/koid stop` quits it. Both
preserve the server and shells. After changing server behavior, use
`scripts/koid stop --all` before reopening Koid to load the new server;
this ends the development sessions. Rebuilding alone does not replace the
answering server: check `scripts/koid koi info --json`, or Machines & Server,
for its actual version and capabilities. An older v6 server can reject
`serverInfo`; its missing capabilities must not trigger an automatic restart.
`scripts/koid log` shows app/server logs.

## Conventions

- Source files stay flat and lowercase under `src/app/` and `src/core/`.
  Swift uses `UpperCamelCase` types and `lowerCamelCase` members. Follow the
  neighboring Zig code: `UpperCamelCase` types, `lowerCamelCase` functions
  and `snake_case` fields and locals.
- Name files for the feature or responsibility they own: `panes.swift`,
  `toast.swift`, `keyboard.swift`. Shared buttons live in `buttons.swift`;
  floating presentation and hover hints in `popover.swift`; action rows in
  `menu.swift`. A feature can contain several related types without adding
  a manager or helper layer just to split a file.
- Tests follow their feature's filename with a `Tests` suffix, in camel case
  for readability (`panesTests.swift`, `tabInputTests.swift`); the lowercase
  rule applies to source files only. Shared private-server fixtures live
  in `tests/app/testServer.swift`; keep AppKit and shared-state checks in
  the serialized `SessionTests` suite when moving tests between files.
  AppKit fixtures share configuration and application events with server checks;
  keep them in this suite so reloads cannot cancel another fixture’s gestures.
- Configuration keys use kebab-case; action IDs use snake_case. Serialized
  names are interfaces: do not rename them merely to match language style.
- Use conventional root names such as `README.md` and `CONTRIBUTING.md`.
  Guides under `docs/` use lowercase names, with hyphens between words.
- Keep documentation about implemented behavior. Put usage in the README
  or reference guides, contribution workflows here, and agent constraints
  in `AGENTS.md`. Update affected links and examples with the code.
- Keep build output, downloaded dependencies, screenshots and logs out of
  source control. The repository's `.gitignore` lists their locations.

## Compatibility and integration boundaries

The [architecture guide](docs/architecture.md#connections-and-protocol)
records the additive v6 operations. Keep Swift/Zig framing, JSON names and
versions compatible. Probe advertised capabilities before new mutations or
creation options; old v6 may silently ignore fields. These features use JSON,
not new `libkoi` C ABI entry points. Preserve older-server sessions while
reporting unsupported operations. Project restore must create fresh shells,
confirm topology/weights through watcher state, and preserve existing jobs
and partial new tabs on failure.

Keep settings ranges consistent across parser, UI, mirrors and wire
validation. The current file/UI ranges are 6–72 points, line height 1–3 and
scrollback 1–32 MiB, defaulting to 32. The app cap is deliberate for reliable
reattachment; JSON appearance separately accepts 0–1024 MiB subject to the
snapshot limit.
When reviewing a different scrollback maximum, inspect these exact owners:

- [`config.swift`](src/app/config.swift): `Config.scrollbackMBRange`, the
  `apply` validation/error text and starter config.
- [`settings.swift`](src/app/settings.swift): the `scrollback-mb` control's
  range and description.
- [`terminal.swift`](src/app/terminal.swift): `applyTerminalConfiguration`'s
  mirror clamp; [`wire.zig`](src/core/wire.zig): `Appearance.valid` and its
  contract comment. Both still allow up to 1024, independently of the
  public file/UI maximum.
- [`configTests.swift`](tests/app/configTests.swift) and the appearance
  validation tests in [`wire.zig`](src/core/wire.zig), plus this guide,
  [Configuration](docs/configuration.md) and
  [Architecture](docs/architecture.md#ownership-and-memory-limits).

The 32 MiB defaults in the two emulators and `Wire.Appearance` are separate
from the maximum; snapshot framing stays capped at 64 MiB. Changing one
limit alone is not a hard-memory or cross-client history guarantee.

Optional shell/agent installs and the CLI wrapper must remain user-click
operations. Skills are single-file guidance, with no guaranteed lifecycle
hooks. Notification initialization must not ask authorization; explicit
notification UI actions own that prompt. Updates require a manually
configured source and user check while the app is unpublished, and open
release pages without automatic binary installation. See
[Configuration](docs/configuration.md) for the implemented controls.

When updating Ghostty, change `GHOSTTY_COMMIT` in
[`scripts/build-ghostty-vt.sh`](scripts/build-ghostty-vt.sh), rebuild, and
review the [third-party notices](THIRD_PARTY_NOTICES.md).

## Licensing

Koi's original contributions are accepted under GPL-3.0-only. Preserve
third-party license notices and record imported code or artwork under its
actual license; see [Third-party notices](THIRD_PARTY_NOTICES.md) and
[Assets](docs/assets.md). App icons are original Koi project artwork.

## Program icons

Adding an application normally requires no Swift or Zig changes. Program
names and styling come from
[`programs.json`](src/app/resources/programs/programs.json). An entry can use
an existing SVG logo, an SF Symbol or a short text glyph:

```json
{
  "runs": ["mytool"],
  "name": "My Tool",
  "symbol": "terminal",
  "colors": ["3B3B42", "26262B"]
}
```

`runs` lists executable names; keep new aliases lowercase. Choose one of
`logo`, `symbol` or `text`. `colors` contains two six-digit hex colors
without `#`; optional `ink` sets the glyph color, defaulting to white.
Optional `mark` provides a separate pane-header `symbol` or `text` glyph.

Use the actual executable names, not arguments (`agent`, not `agent chat`),
and keep aliases unique across the catalog. Lookup strips paths and ignores
case. Node/Bun scripts inside `node_modules` report the owning package's
unscoped name: `@anthropic-ai/claude-code/cli.js` reports `claude-code`.
Include that alias when applicable; do not map generic `cli` or `index`
names to a brand. A local integrated shell reports the command it launched;
remote discovery may report its interpreter or wrapper instead.

The catalog includes OpenCode, Claude Code, Codex, Gemini, Copilot, Aider,
Pi, Amp, Cursor Agent, Factory Droid, Qwen Code, Goose, Crush, Mistral Vibe,
Auggie, Kilo Code, Kimi Code, Cline and OpenHands, plus other CLI tools.
These entries control identification and branding; adding one does not
install an application, alter its terminal colors, or enable speculative
typing or agent lifecycle hooks. Unknown programs keep Koi's `>_` mark on
a neutral tile. Known programs with missing artwork also use `>_`.

### Add an icon

Reuse a bundled `logo`, use an SF Symbol, or use a short `text` glyph.
New SVGs belong in `src/app/resources/programs/logos/`. Use a square viewBox,
self-contained paths/shapes and transparency; Koi tints the image with `ink`.
Check legibility at the 18-point tab tile and 13-point pane-header sizes.
Keep background gradients and ink colors readable together.

For a new SVG, add a record to `logos/sources.json` with `file`, `sha256`
and the immutable upstream `revision`. Records inherit the manifest's
repository and license unless overridden. For artwork outside Simple Icons,
also provide a `source` HTTPS URL and `license` identifier in that record,
add the applicable license text under `licenses/`, and update
[third-party notices](THIRD_PARTY_NOTICES.md) and [assets](docs/assets.md).
Only submit artwork you can redistribute; a generic symbol or your own
text mark is welcome when a logo's license is unclear.

### Check and submit

Run the catalog check on Linux or macOS with Python 3; it needs no downloads,
Zig, Swift, Xcode or third-party Python packages:

```sh
./x programs
```

It checks aliases, fields, colors, glyph choices, SVGs and source checksums,
then runs the validator's regression tests. CI runs it as a separate job;
catalog-only PRs do not require a Mac build. License or notice changes also
run bundle verification because those files are packaged with the app.
On a Mac, the full `scripts/koid test` suite also verifies that AppKit loads
the logos and resolves the SF Symbols. Rebuild and relaunch Koid after
changing the catalog; styles and images are cached for the app's lifetime.

Use the [application PR template](.github/PULL_REQUEST_TEMPLATE/application.md).
Include the command/package names, an upstream application link, the artwork
source and license (if new), check results, and a Koid screenshot when you
have a Mac. State when visual validation needs a maintainer. To confirm the
reported program, run the application in a disposable Koid pane and inspect
`scripts/koid koi ls --json`; never submit credentials or private terminal text.

## Detailed development guidance

The [development reference](docs/development.md) retains fixture isolation,
preview commands, protocol and rendering rules, and dependency/release guidance.
Use `./x mutate` (core) or `./x mutate --app` after changing security boundaries,
limits or lifecycle rules. App tests require macOS; Linux can run `./x scripts`,
`./x programs` and `./x test-core` with the pinned Zig toolchain.
