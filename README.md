# Koi

Koi is a macOS terminal workspace for persistent shells, panes, tabs, and remote machines. It keeps terminal work alive across app restarts, supports split layouts and tab groups, and connects to remote machines over SSH and encrypted UDP.

## Why Koi

- Persistent terminal sessions stay running when the app closes.
- Tabs, panes, and groups can be rearranged without losing shell state.
- The command palette finds work by name, program, directory, machine, and activity.
- Remote systems connect with SSH setup and an encrypted UDP path, falling back to an SSH relay.
- Multiple windows can attach to the same running server while keeping independent selections.
- Project layouts recreate directories, groups, and pane arrangements for new shells.

Koi also recognizes agent-style tooling and coding sessions such as Claude, Codex, Gemini, Copilot, Cursor, and similar CLIs; unknown tools keep Koi's terminal mark instead of a custom icon.

## Get started

### Build from source

Use an Apple silicon Mac running macOS 26+ with Xcode, Swift 6.2+, Zig 0.17.0, and Git.

```sh
git clone https://github.com/arocomputer/koi.git
cd koi
scripts/bundle.sh
open build/Koi.app
```

This build downloads the pinned Ghostty sources and assembles the engine, CLI, server, and app. It does not install the app into `/Applications` unless you opt in.

For development, use Koid at `~/Applications/Koid.app`. See [CONTRIBUTING.md](CONTRIBUTING.md) for the local workflow, test commands, and build expectations.

### Use the app

Some common workflows:

- Open the command palette with `⌘P`.
- Split panes with `⌘D` or `⇧⌘D`.
- Move between panes with `⌘[` and `⌘]`.
- Rename tabs or groups with a double-click.
- Use `⌘C`/`⌘V` for terminal copy and paste.
- Browse remote work in the command palette or machine picker.

See [docs/configuration.md](docs/configuration.md) for settings, keyboard shortcuts, and behavior options.

## Project docs

- [CONTRIBUTING.md](CONTRIBUTING.md) — contributor workflow, prerequisites, testing, and repo conventions
- [AGENTS.md](AGENTS.md) — short operational guide for repository work and AI-assisted changes
- [docs/architecture.md](docs/architecture.md) — server/app ownership, transport, protocol, and implementation overview
- [docs/cli.md](docs/cli.md) — CLI commands, targets, and exit codes
- [docs/configuration.md](docs/configuration.md) — settings, key bindings, and runtime configuration

## Repository status

Koi is under active development. Release builds support signed in-place updates through Sparkle, with an update toast and a daily-check setting. Development builds of Koid do not update themselves.
| [Contributing](CONTRIBUTING.md) | Build, test, Koid previews and program icons |
| [Assets](docs/assets.md) | App artwork, program-logo sources and licenses |

## License

Copyright (c) 2026 Koi contributors.

Koi's original source code, scripts, documentation and app icon artwork are
licensed under the [GNU General Public License, version 3 only](LICENSE)
(`GPL-3.0-only`). It is provided without warranty; see the license for details.
Distributed derivative versions must preserve GPLv3 and provide the
corresponding source under its terms. Private modifications need not be published.

Third-party code and program logos retain their own licenses and notices;
see [Third-party notices](THIRD_PARTY_NOTICES.md) and [Assets](docs/assets.md).
