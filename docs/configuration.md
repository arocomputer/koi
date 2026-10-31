# Configuration

Koi creates `~/.config/koi/config` on first launch. Set `XDG_CONFIG_HOME` to
use `$XDG_CONFIG_HOME/koi/config` instead. `KOI_DIR` overrides this path as
well as state and runtime storage; see [Architecture](architecture.md).

By default, ⌘, opens Settings. Its compact glass window dismisses when it
loses focus or with ⌘W. It has no traffic lights and does not resize, zoom
or enter full screen. Its own save dialogs can take focus without dismissing
Settings. The horizontal categories are **Appearance** (the default),
**Terminal**, **Shortcuts**, **Machines & Server**, **Activity** and **Advanced**. Click a
category, drag the strip with the mouse, use two-finger scrolling, or click
the left/right arrows. Arrows dim and disable at the ends; the strip does
not wrap. Selected categories use the same capsule shape as selected tabs
and collapsed groups containing the selected tab. There is no keyboard
category navigation.

Terminal → Text contains font family, size and line height; Terminal also
contains cursor and input/session controls, including focus-follows-mouse.
Appearance contains background opacity, reduced transparency, animation, tab
placement, pane headers, compact spacing and inactive-pane fading.
Font actions appear under Terminal in shortcut lists and the palette;
Toggle Sidebar and tab placement appear under Appearance.

Search matches across categories by setting name, description, config key,
shortcut name or trigger. Controls show effective values and refresh after
reloads. Text edits remain drafts until Return or **Save**; **Revert** drops
the draft. Sliders save on release, and toggles and choices save immediately.
Each setting has a reset control. Failed validation or writes show an error
and retain the draft. Shortcuts have separate Clear and Reset controls.

Choose **Edit Config File** in the command palette, or **Open config file…**
in Advanced, to open the text file. After editing it, use **Reload Config**
(⇧⌘, by default). App edits write the same file and apply without restarting
shells. `startup-command` affects newly created sessions only.

## File format

Use one `key = value` per line. Blank lines and lines beginning with `#`
are ignored. Inline comments are not supported.
Keys, action IDs and enum values use the case shown below. Unknown keys,
malformed entries and invalid values produce diagnostics in Advanced.
Invalid normal settings keep their built-in defaults; numeric values outside
the supported range are rejected, not clamped. For repeated normal keys,
the last occurrence wins, including an invalid last value reverting to the
default. Valid keybindings override by action in file order.

```ini
# Layout and terminal text
tabs = top
font-size = 14
line-height = 1.2
background-opacity = 0.9
scrollback-mb = 32
option-key = automatic

# A custom shortcut, and an explicitly unassigned action
keybind = cmd+shift+b = toggle_sidebar
keybind = none = reset_terminal
```

## Settings

These are the public file keys; visible labels do not rename them. In
particular, `tabs = side` means Left, and `animation` selects motion.
The removed `active-pane-border`, `color-scheme`, `background`, `foreground`
and `cursor` keys are unknown keys and produce diagnostics.

| Key | Default | Values |
| --- | --- | --- |
| `tabs` | `side` | `side` (left), `top`, or `right`; `left` is also accepted |
| `animation` | `snappy` | `snappy`, `natural`, `off`; system Reduce Motion also disables motion |
| `reduce-transparency` | `false` | `true` or `false`; system Reduce Transparency also applies |
| `font-size` | `13` | 6–72 points |
| `font-family` | System monospace | An installed font family name; empty restores the default |
| `line-height` | `1` | 1–3 times the text line height |
| `background-opacity` | `0.85` | 0–1 |
| `cursor-style` | Program default | `block`, `bar`, `underline`, `hollow`; empty removes override |
| `cursor-opacity` | `1` | 0–1 |
| `cursor-height` | `1` | 0.2–1 of the text box |
| `option-key` | `automatic` | `automatic`, `alt`, `text` |
| `show-pane-headers` | `true` | `true` or `false` |
| `compact-panes` | `false` | `true` or `false` |
| `focus-follows-mouse` | `false` | `true` or `false` |
| `fade-inactive-panes` | `false` | `true` or `false` |
| `notify-blocked` | `false` | `true` or `false` |
| `notify-done` | `false` | `true` or `false` |
| `notify-error` | `false` | `true` or `false` |
| `quiet-when-focused` | `true` | `true` or `false` |
| `startup-command` | Empty | Single-line shell source for new tabs/splits; empty starts an interactive login shell |
| `scrollback-mb` | `32` | Integer 1–32 MiB of estimated engine pages per terminal |

An application's terminal cursor-shape request overrides `cursor-style`.
Synchronized terminal redraws retain the last complete frame until release,
with a one-second fallback for stuck applications. Cursor opacity also applies
to the inverted character under a block cursor. Typing prediction covers remote
panes, including nested ssh sessions and REPLs; full-screen programs and
programs that hide the cursor to draw their own are left alone. It clears on
navigation, paste, and other unpredictable input, then waits for a real echo
before showing predictions again. A predicted cell keeps the background of the
cell it covers and the color of the word it continues, so colored prompts and
autosuggestions do not flash the wrong colors.
Font family selection includes installed-font search and a sample; Terminal
also previews text and cursor settings, including the full 1–3 line-height
range.

`option-key = automatic` preserves native Option text entry and terminal
navigation bindings. `alt` sends Option as terminal Alt, bypassing native
dead-key entry; `text` favors native special-character entry, including in
Kitty keyboard mode. Mac line/word editing bindings still take precedence,
and an active input-method composition remains native.

`startup-command` is passed intact to the login shell with `-c`, not split
into executable arguments. Its process can exit when the command finishes;
use an explicit `exec` when appropriate. Existing shells keep running.
A server must advertise `startup` before Koi uses a configured command;
an unsupported request is reported without silently opening a different shell.

Scrollback changes apply to app mirrors and, on servers advertising
`configurePane`, to the authoritative terminal, including existing panes.
The budget estimates engine pages, not total process memory. Attach/edit
snapshots remain limited to 64 MiB, so a large history can exceed the frame
limit. Older clients may reapply their own history limit; this is not a
cross-client privacy guarantee. The JSON protocol accepts 0–1024 MiB, while
the config file and Settings deliberately cap the range at 1–32 MiB,
defaulting to 32 MiB, for reliable reattachment.

The app uses a fixed dark glass palette; background opacity is configurable
and defaults to 0.85. Focused and unfocused pane outlines are always neutral,
with no accent-border setting. Pane headers default to visible at 42 points
with 8-point split gaps; `compact-panes` uses 32-point headers and 4-point gaps.
`show-pane-headers = false` hides headers. Focus-follows-mouse and inactive-pane
fading are optional and default off. Animation defaults to `snappy`, with
`natural` and `off` also available. macOS Reduce Motion disables motion, and
either `reduce-transparency` or macOS Reduce Transparency selects solid backing.

## Keyboard shortcuts

Write a binding as `keybind = <trigger> = <action>`. The Settings key recorder
edits the same format. The palette, menu and hover hints show effective
bindings, including changes loaded from the file.

Modifiers are `cmd`, `shift`, `ctrl` and `alt`. Keys can be a single character or one of `left`,
`right`, `up`, `down`, `enter`, `space`, `tab`, `plus`, `minus`,
`equal` and `comma`. Use `plus` for the + key because + separates trigger
parts. Use `none` to unassign an action. Clear writes `none`; Reset removes
the override and restores the built-in binding.

Recording consumes keys only during that recording session; Escape cancels.
Conflicts with another configurable action, including its default binding,
are shown and rejected before saving. Conflicts loaded from a hand-edited
file are reported in Settings rather than silently reassigned.

| Area | Configurable action IDs |
| --- | --- |
| Palette | `command_palette` |
| Window | `new_window`, `full_screen` |
| Tabs | `new_tab`, `close_tab`, `next_tab`, `previous_tab` |
| Panes | `close_pane`, `new_split`, `new_split_down`, `toggle_zoom`, `next_pane`, `previous_pane` |
| Pane focus | `focus_split_left`, `focus_split_right`, `focus_split_up`, `focus_split_down` |
| Appearance | `toggle_sidebar` |
| Editing | `copy`, `paste`, `select_all`, `find` |
| Terminal | `increase_font_size`, `decrease_font_size`, `reset_font_size`, `clear_scrollback`, `reset_terminal`, `previous_prompt`, `next_prompt`, `insert_path`, `go_directory` |
| Projects | `save_project`, `open_project` |
| Activity | `show_activity` |
| Settings | `open_config`, `reload_config`, `check_updates` |

Numbered-tab selection still uses fixed menu shortcuts. `open_config` opens
Settings; **Edit Config File** is a separate palette command. See the
[default shortcuts](../README.md#default-shortcuts).

## Activity and optional integrations

**Show Activity** lists non-idle programs across connected machines and can
focus their panes. Status can come from server inference, legacy OSC 7501,
or explicit [`koi status`](cli.md).

Completion cues are for agent applications identified in Koi's program catalog:

- While viewing another machine, a completed agent shows a toast with **Open Pane**.
  It switches to that machine, tab and pane without creating a new shell.
- On the same machine, an unread completion appears as a small yellow circle at
  the upper-right of the tab's program icon, in both top and side tab bars.
  In split tabs, each completed pane also gets a circle at the upper-right of
  its own header icon. Circles overlap their icon's edge slightly.
- Visiting the completed pane clears its circle across windows. Work starting
  again, removal of the pane or another program taking over also clears it.
  An already focused pane needs no unread indicator.

These in-app cues do not need notification permission. Agent hooks in Advanced
can report turn completion automatically. Initial observations and repeated
statuses stay silent; ordinary commands do not produce completion cues.

System notifications for agents are separate: blocked, done and error each
default off. `quiet-when-focused` suppresses system notifications while Koi is
active and defaults on. Suppressed transitions never produce catch-up alerts.

Koi does not request notification authorization at startup. Enabling a
notification toggle in Settings or clicking **Enable Notifications…** requests
permission; loading `notify-* = true` from the file does not itself prompt.
Delivery requires system authorization as well as the relevant toggle.

Clicking a notification focuses its existing pane using stable machine, tab
and pane IDs. Koi retries for up to two seconds while initial attachment
settles. A stale notification never starts a connection or creates a shell.

Shells Koi starts carry its prompt integration without touching your files:
zsh starts in a Koi-owned `ZDOTDIR` whose startup files run your own with
your `ZDOTDIR` restored, and fish finds a Koi vendor configuration on
`XDG_DATA_DIRS`. Inside Koi, those shells emit OSC 133 prompt markers for
Previous/Next Prompt and name each command as it starts. Pane headers show
commands that continue running, such as `make` while it runs `cc`, after a
brief delay that avoids flashing for short commands.
For bash, source `"$KOI_SHELL_INTEGRATION/bash/koi.bash"` from `~/.bashrc`.

Advanced offers optional agent guidance. Only clicking Install writes files:

- Codex installs `.agents/skills/koi-terminal/SKILL.md`; Claude Code installs
  `.claude/skills/koi-terminal/SKILL.md`, under Home or the chosen project.
  These are single-file guidance skills for stock CLI use and explicit
  status reporting. They install no hooks and cannot make an agent report.
- **Agent Status Hooks** make Claude Code and Codex report for themselves.
  Install adds a few entries to the agent's own settings file: Claude Code's
  `~/.claude/settings.json` (`.claude/settings.local.json` for a chosen
  project, which Git ignores) and Codex's `.codex/hooks.json`. Each runs
  `koi status` on a lifecycle event: `working` when a prompt is submitted or a
  tool finishes, `blocked` on a permission request, `done` when the agent
  stops, `error` when Claude Code's turn fails, and `idle` when a session ends
  or Codex is interrupted. Outside a Koi pane they do nothing and always exit 0.

Installers preserve foreign or edited files; removal deletes only unchanged
Koi guidance. Hooks are recognized by a `# koi-status` mark at the end of
their command: Install replaces older Koi entries instead of adding more,
Remove takes out only those, and every other key and hook in the file stays.
The first change keeps a `.koi-backup` copy. A settings file that is not valid
JSON, or whose hooks Koi does not recognize, is left untouched with an error.
Settings files are rewritten as indented JSON with sorted keys.

## Server, diagnostics and updates

Machines & Server manages local/SSH profiles and displays facts from the
running server: version, PID, protocol, uptime and advertised capabilities.
Attached-pane connections show their actual route; advertised transports
are not proof that a pane uses them. Refresh is read-only.

Machine icons use the reported Mac model family or a generic Linux server
symbol. Koi checks in the background after connecting, using SSH for remote
machines, and remembers the last result while a machine is offline. The check
uses only the model name and does not depend on the server version.

**Help → Diagnostics…** or **Diagnostics…** in the palette opens a resizable
glass window with four horizontal sections: **Overview**, **Connections**,
**Rendering** and **Recent Issues**. Its endpoint picker does not change the
active session, connect or start processes. Refresh probes only an existing
control connection; server details show their cached check time. Automatic
snapshot updates run at 1 Hz only while visible. Closing or minimizing stops
the timer; Pause stops automatic snapshot updates.

Rendering shows this window's attached terminal renderers: device, drawable
size, submitted/completed/failed frames, pending/in-flight work, deferral
counts, latest/maximum CPU frame time, latest GPU execution time and allocated
atlas/vertex-buffer bytes. CPU time covers assembly through commit, including
drawable waits; GPU time requires valid successful completion timestamps.
These measurements cover terminal rendering, not GPU utilization, total
process memory, WindowServer composition or sidebar animation. **Reset
Counters** starts a new reporting interval.

Recent Issues combines up to 100 deduplicated app summaries with retained
errors from live attached renderers, displaying the newest 100 entries.
Filter searches summaries; **Clear History** clears the displayed history
without deleting log files. Raw logs and terminal text are excluded.
**Open Local Server Log…** explicitly opens the local log in a viewer.

**Copy Report** and **Export…** use the inspected endpoint's report and its
cached facts, including renderer and recent-issue summaries. Export opens a
save panel. Reports redact hosts and tokens and exclude terminal text, log
contents, raw config values and environment dumps. A validated server version
with its 64-digit lowercase build hash is preserved only in the server-version
field, unless it contains a configured host alias. Advanced also offers log,
copy/export and [CLI wrapper](cli.md) actions.

Koi updates itself with [Sparkle](https://sparkle-project.org). About once a day,
and when you choose **Check for Updates…**, it reads the appcast at
`github.com/arocomputer/koi/releases/latest/download/appcast.xml`. When a newer
release exists, a toast in the corner of the window in front says so, with
**Later** and **Update**. Update downloads the archive in the background, checks
it, and the toast then offers **Restart**; choosing Later instead installs it
the next time Koi quits. Restarting is safe: shells live in the server, and the
next launch shows them again. Cancel stops a check or a download.

- Koi reads only an appcast signed with its update key, and installs only an
  archive signed with that same key, checked before the archive is unpacked.
  An altered or foreign archive is refused and the installed app is left alone.
- The request goes to GitHub and carries the app's name and version, as any
  download does. Koi sends no profile of this Mac, and the check never sends
  terminal contents, hostnames or settings.
- A check that finds nothing, or fails, says nothing unless you asked for it;
  asked for, it says "Koi is up to date" or why it could not check.
- Settings → Advanced has the daily check's switch, **Check Now** and the
  version. The switch is Sparkle's own setting in the app's preferences, not the
  config file.
- A build with no feed and key in its `Info.plist` does not update: Koid, and
  the test app. Its menu item says so.

The parser and controls are in [`config.swift`](../src/app/config.swift)
and [`settings.swift`](../src/app/settings.swift); action IDs are defined
in [`shortcuts.swift`](../src/app/shortcuts.swift).

### Closing panes

The pane header's close button is dimmed and disabled when it is the only pane
in its tab. Split panes retain an active close button. Use **Close Tab** when
you intend to end a single-pane tab; explicit tab closing and close shortcuts
keep their existing behavior.
