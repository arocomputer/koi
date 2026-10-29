# Contributing to Koi

Use Koid when developing so builds and experiments stay separate from the
Koi used for everyday work. Read the [architecture](docs/architecture.md)
before changing session ownership, transport or the wire protocol.

## Build and test

The app targets Apple silicon and macOS 26+. The package requires Swift 6.2+
and Koi declares Zig 0.17.0 as its minimum. Use the Zig toolchain required
by the pinned Ghostty source too. A full Xcode installation is needed for
Metal, asset compilation and app signing.
Python 3 is required by the isolated test runner and script regressions.

The locally verified toolchain is Xcode 27.1 (build 27A9275), Swift 6.4
and Zig 0.17.0. These are tested versions, distinct from the declared minimums.
Select the intended Xcode with `DEVELOPER_DIR` or `xcode-select` and check
`xcodebuild -version`, `swift --version` and `zig version` before comparing
builds. The hosted workflow explicitly selects Xcode 26.6 and Zig 0.17.0
from the macOS 26 ARM runner image; it does not depend on `macos-latest` or
the image's default Xcode selection.

From the repository root:

```sh
./x check                  # scripts, catalog, full isolated tests, release bundle
./x scripts                # portable regressions, no native toolchain
./x programs               # catalog and artwork validation
scripts/koid build
scripts/koid run
```

`./x` is the shared local/CI entry point; `./x help` lists its commands.
`./x test` delegates to `scripts/koid test`, and `./x bundle` runs
`scripts/bundle.sh` followed by signature verification. Neither installs or
launches an app. Development builds and interaction remain under `scripts/koid`.

`build` fetches dependencies as needed, builds the Mac and Linux server
binaries, and installs Koid at the same path across worktrees. Its bundle ID
is `com.fschrhunt.koid`; its config, layout, server log and socket live under
`~/.local/state/koid`. Its macOS preferences are separate from Koi's too.

`test` prepares dependencies, runs `zig build test`, and runs `swift test`.
`scripts/koid test --headless` (also `./x test-app`) prepares the same native
dependencies and runs only the hosted Swift subset. It uses the same lock,
server snapshot and cleanup as the full suite. `./x test-core` prepares just
the pinned engine source and runs native Zig tests with a private `KOI_DIR`;
it does not build the Apple framework or release server binaries.
Each invocation owns a short temporary root and exports its own `KOI_DIR`,
`TMPDIR` and test-only `KOI_TEST_ROOT`. Server fixtures use the latter directly
because Foundation can resolve the system temp directory despite `TMPDIR`.
An exit trap cleans only that invocation's fixture servers and
directories, including after failures and handled signals. Concurrent runs
must never clean each other's files. Integration tests use those temporary
directories; they do not
use the development or daily server. `KOI_SERVER_BIN` can select a different
server binary for these tests; each run snapshots its selected binary.
Runs in one checkout queue behind an OS-released lock for the entire shared
build/test pipeline. Separate checkouts have independent locks. Cleanup
signals only registered fixture processes whose live executable or command
matches the run's private binary; stale PID markers are ignored.
AppKit fixtures host windows/views offscreen;
installation tests use private fixture homes and fake binaries, notification
tests inject delivery, and update tests inject fetching. Keep new checks
isolated the same way: no real notification authorization, update requests,
agent installs, home-config reads or writes to existing sessions.

The commands above cover development build/run/test and the ordinary release
bundle. Record commands and results when submitting; distinguish source
review, automated checks and visual inspection. For a docs-only task that
forbids execution, review source and links and report runtime checks as unrun.

After dependencies have been built, a focused app test can run directly:

```sh
swift test --filter PaletteSearchTests
zig build test -Dtest-filter=watcher
```

Before submitting a code change, run `scripts/koid test` and
`scripts/bundle.sh`. Add focused regression tests for behavior changes.
Check visual changes in Koid rather than writing tests that assert styling
constants. Settings checks should cover search, current values, validation,
reset/unassignment and conflicts; category navigation remains a horizontal
mouse-drag/two-finger-scroll strip with dimmed click arrows and no keyboard
category handlers. Check Settings dismissal on blur and Command-W, and that
zoom/fullscreen actions leave its compact size unchanged. For pane
motion, check destination grids before reveal, clipping, reversals and the
temporary static shell; do not infer GPU performance from layout tests.
Keep checks for `snappy`/`natural`/`off`, configurable opacity/transparency,
pane headers, compact spacing, inactive-pane fading and focus-follows-mouse,
including config persistence and system Reduce Motion/Transparency. Focused
and unfocused pane outlines stay neutral; there is no active-border setting.

The benchmarks in `tests/app/benchmarkTests.swift` run with every full suite.
They print engine parse rate, full and incremental frame assembly, snapshot
cost and a keystroke's round trip through a private server and real process,
using both a local socket and the encrypted UDP link over loopback. Loopback
does not measure WAN latency or typing-to-display latency.
Parse/frame/echo measurements have regression bounds; echo polling also has
a monotonic deadline so a missing response fails instead of hanging.
Snapshot timings are informational, with restored screen text checked for
integrity. Read the figures with:

```sh
swift test --filter "engineWriteAndFrameAssembly|keystrokeEchoRoundTrip" 2>&1 | grep -E "engine|frame|snapshot|keystroke"
```

The app logs `first pane ready N ms after launch` once per start and shows
it in Diagnostics; that is the startup number to watch.

Keep the main thread empty while output streams: work done per output
batch (`TerminalView.handle`) must not touch SwiftUI state or rebuild
views. Header and tab updates come from server tree changes, never from
output bytes.

The test process keeps its own `KOI_DIR` under the invocation's temporary
root, so no check reaches the daily or Koid server. The test runner stops
only servers found within that root and removes it on exit.

Script regressions run without real builds, hardware or existing sessions:

```sh
sh tests/scripts/koid-test-isolation.sh
python3 tests/scripts/buildProvenanceTests.py
```

The [CI workflow](.github/workflows/ci.yml) runs script regressions and catalog
checks on Linux, then selects native jobs from the complete PR diff. Ordinary
docs and catalog-only changes skip native builds. App changes run hosted Swift
tests and bundle verification; core, build, workflow and unknown inputs also
run core tests in parallel. Packaged licenses and notices still require bundle
verification. Main pushes and manual runs execute all checks. The final
`CI required` check rejects failures, cancellations and unexpected skips.

Hosted macOS runners do not reliably expose Metal. The explicit Swift subset
in `scripts/koid` does not cover every non-GPU integration test; the full
AppKit/renderer suite and performance checks remain required on an Apple
silicon Mac with Metal. Catalog-only CI validates SVG/schema/provenance, not
AppKit rendering or SF Symbol availability. It performs no publishing or
installation. See [CI and repository maintenance](docs/ci.md) for cache
boundaries, check names and the branch protection policy.

Tab-strip integration checks use private servers and offscreen hosted views.
To save their layout and drag previews without capturing the screen:

```sh
KOI_VISUALS="$PWD/build/previews" swift test --filter tabStripsCommitUsingTheirRenderedTargets
```

The images contain only the fixture's chrome. Tests do not drive the desktop
or send prompts to programs running in existing sessions.

For grouped palette and open-work previews in that directory:

```sh
KOI_VISUALS="$PWD/build/previews" swift test --filter groupedHomeAndWorkBrowserFitTheSmallestWindow
```

Optional offscreen Settings view previews of the default Appearance category
in dark appearance at the normal width of 700 and a narrow fixture width of
520 are defined in
[`settingsTests.swift`](tests/app/settingsTests.swift). Save the two PNGs with:

```sh
KOI_VISUALS="$PWD/build/previews" swift test --filter settingsWindowPreviews
```

This fixture does not activate a window or read the user's configuration.
It is enabled only when `KOI_VISUALS` is set.

For offscreen Diagnostics window previews:

```sh
KOI_VISUALS=$PWD/build/previews swift test --filter diagnosticsWindowPreviews
```

Review Overview, Connections, Rendering and Recent Issues, including their
shared rounded rectangle Capsule selection. Diagnostics inspection must preserve session
selection; Refresh must use existing controls without connecting or starting
processes. Check that copy/export follows the inspected endpoint, Pause stops
automatic snapshot updates, close/minimize stops the timer, and Clear History
keeps log files. Renderer counters and timing describe attached terminals;
they do not establish GPU utilization or whole-window animation performance.

After dependencies are available, focused checks for the newer behavior can
be selected without running Koid's app or attaching to its sessions:

```sh
swift test --filter 'ProjectTests|ActivityTests|UpdatesTests|IntegrationsTests|InstallationTests'
swift test --filter closingOneWindowPreservesAnotherWindowsSelectionAndServer
swift test --filter 'settings|accessibility'
zig build test -Dtest-filter=serverInfo
zig build test -Dtest-filter=reportStatus
```

Private-server tests still launch their own test server. Offscreen checks
verify the exercised layout/ownership contracts; they do not establish
on-screen animation quality or GPU throughput.

Address Sanitizer is recommended for input, accessibility, native-handle
ownership and connection changes. Run relevant Swift tests, for example:

```sh
swift test --sanitize address --filter 'KeyboardTests|CompositionTests|InputModeTests|SocketTests|accessibility'
swift test --sanitize address --filter closingOneWindowPreservesAnotherWindowsSelectionAndServer
```

Core tests use Zig's testing allocator for leak checks and allocation-failure
tests. Exercise slow peers and concurrent close paths in private test
servers. A green sanitizer run covers the exercised paths; it is not a
claim that every native library or GPU access was instrumented.

### Build destinations

| Command | Destination |
| --- | --- |
| `scripts/bundle.sh` | `build/Koi.app`; does not install it |
| `scripts/bundle.sh --install` | Builds, then replaces `/Applications/Koi.app` |
| `scripts/koid build` | Replaces `~/Applications/Koid.app` |

`KOI_BUNDLE_OUTPUT=/absolute/path/Koi.app scripts/bundle.sh` selects a separate
release-bundle destination, useful while running `build/Koi.app` or checking
a clean source tree. It does not change Koid's fixed destination. Choose a
dedicated output directory: bundle assembly replaces its destination.

`build.zig.zon` is the authoritative semantic version for the core and app.
Bundle version fields derive from it. Scripted core builds include the pinned
engine revision, Zig executable/version, Xcode/SDK selection, source/build inputs and target
arguments in their version digest. Core output reuse requires that digest and
all packaged binaries, library and headers; test fixtures snapshot `build/core/koi`.
The engine cache validates the checkout,
refuses tracked local edits, and invalidates when its build inputs change.
Direct `zig build` is explicitly `unversioned` unless supplied with a version;
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
