# Koi

Koi is a macOS terminal with persistent shells, tabs and split panes. It uses
[libghostty-vt](https://github.com/ghostty-org/ghostty) for terminal emulation,
Metal for rendering, and AppKit and SwiftUI for its interface.

- Shells keep running when you quit or close the app.
- Tabs can live on the left, top or right, with groups, pane resizing
  and drag-to-reorder.
- The command palette searches actions and open work by name, program,
  directory, machine and activity.
- Remote machines connect through SSH setup and an encrypted UDP link, with
  an SSH relay when UDP is unavailable.
- Multiple windows select work independently while sharing running servers.
- Named project layouts recreate directories, groups and splits in new shells.
- Searchable Settings and keyboard shortcuts apply without restarting.
- Activity reporting and optional notifications help find work needing attention.

Application tiles recognize coding agents such as OpenCode, Claude Code, Codex,
Gemini, Copilot, Amp, Cursor Agent and Qwen Code. Unknown applications retain
Koi's `>_` mark. Icons and colors come from a bundled catalog; [adding your
application](CONTRIBUTING.md#program-icons) usually needs only a JSON entry,
with a Python-only check available before submitting a PR.

## Build from source

Use an Apple silicon Mac running macOS 26 or later, a full Xcode installation
with Swift 6.2 or later, Zig 0.17.0, and Git. The locally verified combination
is Xcode 27.1 (Swift 6.4) and Zig 0.17.0; the declared minimum toolchains
have not all been independently tested. Run from the repository root:

```sh
scripts/bundle.sh
open build/Koi.app
```

The first build downloads the pinned Ghostty source and builds the engine,
server, CLI and app. Dependencies and build output are generated locally.
A normal build leaves installed applications alone.

For development, use **Koid**, the separate app at `~/Applications/Koid.app`.
See [Contributing](CONTRIBUTING.md) for its build and test workflow. To replace
the installed daily app at `/Applications/Koi.app`, use
`scripts/bundle.sh --install` explicitly.

## Using Koi

The menu bar is organized into **File, Edit, View, Window and Help**. File
contains windows, tabs, paths and project layouts; **View → Pane** contains
split, zoom and pane navigation. **Help → Diagnostics…** opens connection,
rendering and recent-issue details; it is also available in the palette.
Help also opens logs and copies/exports redacted reports. Menu shortcuts
follow your configured bindings.

Quitting detaches the app from its server. Reopening reconnects to the running
shells and their scrollback. **New Window** (⌘N) attaches another client to
the same servers with independent tab and pane selection. Closing a window
preserves jobs, including when it is the last window. Closing a pane ends
its process; closing a tab ends all its panes. Restarting the server ends its sessions.

Open the command palette with **⌘P**. Commands appear directly under feature
headings such as Tabs, Panes and Terminal. Longer lists scroll within a compact
card. Choose **Open Tabs & Panes** to browse open work, or type to search the
complete catalog, including queries such as `codex waiting`, `claude working`
or a directory name. Choosing work on another connected machine switches to
it. Use ↑/↓ and Return to select,
Back to return to the previous list, and Escape to close.

Hover over a toolbar or pane control to see its configured shortcut. These
hints do not take keyboard focus. Machine pickers and action menus use the
same glass styling.

Choose **Left**, **Top** or **Right** in Settings → Appearance or the command palette.
The compact machine button beside the traffic lights opens the machine
picker in Top placement. Vertical rails contain the tabs and groups; drag
their inner edge to adjust the width. ⌘S moves the pane over either vertical
rail and its header; press it again to uncover them. Open Settings with ⌘,;
machine management remains available through the command palette and
Settings → Machines & Server. Settings is compact, closes when it loses focus
or with ⌘W, and does not resize, zoom or enter full screen.
Its categories are **Appearance** (the default), **Terminal**, **Shortcuts**,
**Machines & Server**, **Activity** and **Advanced**, in a horizontal glass
strip: click, mouse-drag or two-finger-scroll it, or use the arrows, which dim
at either end. There is no keyboard category navigation. Search spans all categories; effective
values, per-setting resets and shortcut conflict feedback are described in
[Configuration](docs/configuration.md).

Drag a divider to resize panes; double-click it to reset the split. Drag a
pane header to swap panes. Drag a tab to show an insertion cue, then release
to reorder it. Tabs stay in their real positions throughout the gesture.
Choose **Move or Group…** in a tab's context menu to create a group or move
to an existing one. Dropping on a named group header also moves into it.
Drop at a group's outer edge, at the end of the strip, or choose
**Move Out of Group** to leave it.
Escape cancels a tab or pane drag. Tab strips scroll near their edges during
dragging. Double-click a tab or group name to rename it in either layout.
Drop files onto a terminal to insert their shell-quoted paths.

Double-click terminal text to select a word, or triple-click to select a
logical line, including its soft wraps. Drag past the pane's top or bottom
edge to extend a selection through scrollback. Hold Shift when starting a
drag to select text inside a program that captures the mouse.
Use ⌘C to copy that selection. Ordinary drags in mouse-aware applications
belong to the application; their OSC 52 text-copy requests reach the Mac
clipboard too, including over remote connections. Clipboard writes accept
UTF-8 text up to 1 MiB; applications cannot read the Mac clipboard through
terminal escape sequences. Use ⌘V to paste.

Terminal accessibility exposes a read-only text document for screen and
scrollback, selected text, visible ranges and native text navigation.
Accessibility queries do not replace terminal input or input-method text.

Input methods display uncommitted text at the terminal cursor, with a
candidate window that follows the composition caret. Multiline pastes use
bracketed paste when the running program enables it.

### Projects, activity and terminal tools

Use **Save Project Layout…** and **Open Project…** from the palette to name
and reopen a layout on its saved machine. Opening creates **new shells** in
the saved directories, with tab/group names, order, split topology and
relative weights. It does not resume processes or restore terminal contents.
The normal save action does not infer startup commands from running jobs.
A failed restore preserves existing tabs and leaves any new partial layout
open for inspection. **Manage Saved Projects…** renames or removes recipes
without closing work.

**Clear Scrollback** (⌘K) preserves the visible screen; **Reset Terminal**
resets engine state while preserving the shell, PTY, size and terminal
defaults. These actions require support from the running server and do
not change PTY termios settings. **Insert Path…** and **Go to Directory…**
quote paths for the shell; remote panes ask for a remote path. Zsh and fish
shells started by Koi carry its prompt integration, which enables
**Previous/Next Prompt** and exact program names in pane headers.

**Show Activity** lists non-idle work across connected machines. Programs can
report status using [`koi status`](docs/cli.md); output inference and legacy
status reports also contribute. Notifications for waiting, completion and
errors are opt-in, quiet while Koi is focused by default, and never request
permission at startup. Clicking a notification focuses its existing pane;
stale notifications do not start connections or shells. Settings → Advanced
offers optional single-file Codex/Claude guidance. These skills teach CLI
status reporting; they install no agent lifecycle hooks and do not guarantee
automatic status reports.

Koi uses a fixed dark glass palette with neutral outlines for focused and
unfocused panes. Settings → Appearance controls background opacity (default 0.85),
reduced transparency, animation (`snappy`, `natural` or `off`), tab placement,
pane headers, compact spacing and inactive-pane fading. Terminal settings
include fonts, line height, cursor style, height and opacity, and optional
focus-follows-mouse. macOS Reduce Motion and Reduce Transparency are respected.
Selected tabs in every placement and collapsed groups containing the selection
use a glass fill and faint rim. Settings and Diagnostics categories use a softer
selection fill; all share Koi's rounded rectangle Capsule shape. See
[Configuration](docs/configuration.md) for Option-key policies, scrollback
limits and integration details.

Diagnostics has four horizontal glass sections: **Overview**, **Connections**,
**Rendering** and **Recent Issues**. Its machine picker inspects an endpoint
without switching sessions or connecting; Refresh probes an existing control
connection. Copy/export uses the inspected endpoint's report. Automatic
display updates run once per second while visible; Pause freezes those updates,
and closing or minimizing stops the timer. Recent Issues combines bounded app
summaries and retained renderer errors, excluding raw logs and terminal text.
**Clear History** keeps log files; **Open Local Server Log…** opens the local log
explicitly.

Koi is not published yet. **Check for Updates…** requires a user-configured
HTTPS release URL and a manual check. It opens release pages and does not
automatically download or install binaries. Advanced also offers logs,
copying and save-panel export of redacted diagnostics, and an opt-in CLI
wrapper installer.

### Default shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘P | Open the command palette |
| ⌘N / ⌘T | New window / tab |
| ⌘D / ⇧⌘D | Split right / down |
| ⌘W / ⇧⌘W | Close pane / tab |
| ⇧⌘↩ | Zoom or unzoom a pane |
| ⌥⌘ arrows | Focus the pane in that direction |
| ⌘[ / ⌘] | Previous / next pane |
| ⇧⌘[ / ⇧⌘] | Previous / next tab |
| ⌘1…⌘9 | Select a numbered tab |
| ⌘S | Show or hide the left/right sidebar |
| ⌘F / ⌘K | Find in scrollback / clear scrollback |
| ⌘↑ / ⌘↓ | Previous / next prompt (requires prompt markers) |
| ⌃⌘I / ⇧⌘G | Insert path / go to directory |
| ⌃⌘F | Toggle full screen |
| ⌘C / ⌘V | Copy selection / paste |
| ⌘A | Select terminal text |
| ⌘+ / ⌘− / ⌘0 | Increase / decrease / reset text size |
| ⌘, / ⇧⌘, | Settings / reload config |

In a shell, ⌘←/⌘→ move to the start/end of a line, ⌥←/⌥→ move by word,
and ⌘Delete deletes to the start of the line. Unbound Command combinations
send nothing in legacy keyboard mode. Programs that enable the Kitty
keyboard protocol can receive extended keys.

Shift+Enter is sent as a distinct modified key using the running program's
keyboard protocol. Programs that bind it to a newline can accept multiline
input; newline handling and automatic indentation belong to that program.

## Guides

| Guide | Contents |
| --- | --- |
| [Configuration](docs/configuration.md) | File format, settings, supported keybindings |
| [CLI](docs/cli.md) | Commands, targets and exit codes |
| [Architecture](docs/architecture.md) | App/server responsibilities, transport and storage |
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
