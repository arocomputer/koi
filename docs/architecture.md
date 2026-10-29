# Architecture

Koi separates terminal ownership from the Mac interface. A Zig server owns
the PTYs and processes; the Swift app attaches to them. The same `koi`
executable provides the server and CLI, while `libkoi` exposes the remote
link client to Swift.

```mermaid
flowchart LR
    App[Swift app] -->|Unix socket| Local[Local koi server]
    CLI[koi CLI] -->|Unix socket| Local
    Local --> Shells[PTYs and shells]
    App -->|Encrypted UDP or SSH relay| Remote[Remote koi server]
    Remote --> RemoteShells[Remote PTYs and shells]
```

## Session lifecycle

The server starts on demand and runs independently of the app. Detaching or
quitting a client leaves shells running. The server retains terminal state
and scrollback and supplies a snapshot when a pane attaches. A server
restart ends its processes. Automatic layout metadata describes existing
sessions; explicitly opening a named project recipe creates fresh shells.

Explicitly closing a pane, tab or group removes it from the visible tree
before child teardown finishes. The pane's reader handles hangup and bounded
escalation separately, retaining the child and pane until cleanup is safe.
Closing a tab therefore does not wait for its shell to exit. PTY EOF also
removes the pane before child cleanup, so normal exit avoids that wait too.

The app mirrors each attached pane in its own libghostty-vt terminal. Core
Text supplies glyphs and Metal draws them. AppKit owns the window, terminal
views and input integration; SwiftUI supplies tab bars, headers and floating
controls. Each window owns its selection, focus, workspace connections and
terminal mirrors independently while attaching to the same servers and shared tab
tree. Closing one client detaches only its connections and preserves jobs.
The application owner shares activity tracking and the project catalog.

The main entry points are [`server.zig`](../src/core/server.zig),
[`workspace.swift`](../src/app/workspace.swift),
[`terminal.swift`](../src/app/terminal.swift) and
[`renderer.swift`](../src/app/renderer.swift).

Source is flat under `src/app/` and `src/core/`; follow feature ownership
rather than adding a layer for each helper. Useful boundaries are:

| Responsibility | Sources |
| --- | --- |
| Window ownership, workspace selection, tabs and pane presentation | [`app.swift`](../src/app/app.swift), [`window.swift`](../src/app/window.swift), [`workspace.swift`](../src/app/workspace.swift), [`tabs.swift`](../src/app/tabs.swift), [`panes.swift`](../src/app/panes.swift) |
| Connection lifecycle and routing | [`connections.swift`](../src/app/connections.swift), [`transport.swift`](../src/app/transport.swift), [`endpoint.swift`](../src/app/endpoint.swift), [`remote.swift`](../src/app/remote.swift) |
| Configuration, Settings and fixed palette | [`config.swift`](../src/app/config.swift), [`settings.swift`](../src/app/settings.swift), [`theme.swift`](../src/app/theme.swift) |
| Project recipes and current activity | [`projects.swift`](../src/app/projects.swift), [`activity.swift`](../src/app/activity.swift) |
| Running-server facts and support | [`server.swift`](../src/app/server.swift), [`updates.swift`](../src/app/updates.swift), [`diagnostics.swift`](../src/app/diagnostics.swift), [`diagnosticswindow.swift`](../src/app/diagnosticswindow.swift) |
| Terminal text accessibility and opt-in installation | [`accessibility.swift`](../src/app/accessibility.swift), [`install.swift`](../src/app/install.swift), [`integrations.swift`](../src/app/integrations.swift) |
| Storage and development previews | [`layout.swift`](../src/app/layout.swift), [`paths.swift`](../src/app/paths.swift), [`koid.swift`](../src/app/koid.swift) |

## Connections and protocol

Control connections watch tabs/groups and issue commands. Pane connections
attach by pane ID and carry snapshots, output, input and resize events.
The wire definitions in [`wire.zig`](../src/core/wire.zig) and
[`wire.swift`](../src/app/wire.swift) must agree on framing, message kinds,
payloads and protocol version. Their source text is language-specific.
Incompatible changes require updating the version on both sides. Socket
names include that version so incompatible clients use separate sockets.

The current protocol remains **v6**. New control operations and fields are
additive JSON; they do not extend the `libkoi` C ABI. `serverInfo` returns
`serverVersion`, `serverPID`, `protocolVersion`, `uptimeSeconds`, `transports`
and `capabilities` from the answering process. The version is the package
version plus a digest of the core sources, computed by `scripts/build-core.sh`
and stamped into the binary (`koi version` prints it), so replacing a binary
on disk does not change the identity of a server already running, and the
app can tell when the local server predates the build it carries.

Clients must require an explicit capability before using an additive option:
older v6 servers can ignore unknown JSON fields. Unsupported features are
reported or disabled without replacing the server or ending its sessions.
Existing commands continue to work without the new options.

| Capability | Control contract |
| --- | --- |
| `serverInfo` | Read-only server identity and supported features |
| `clearPane` | Erase history while preserving screen, modes and parser |
| `resetPane` | Replace engine state, preserving process/PTY, size and configured defaults |
| `configurePane` | Apply default foreground/background/cursor colors and history budget; creation also accepts `appearance` |
| `startup` | `newTab`/`splitPane` accept shell source in `startup`, passed intact to the login shell with `-c` |
| `reportStatus` | Set an exact pane's foreground-program status without terminal output |
| `splitCwd` | `splitPane` honors explicit `cwd` rather than silently inheriting |
| `resizeSplitWeights` | `resizeSplit` accepts a full positive finite `weights` array, normalized per child, mutually exclusive with `ratio`/`index` |

Clear, reset and configure prepare a replacement engine and bounded snapshot
before committing, then broadcast that snapshot to attached mirrors. Failure
leaves the authoritative engine unchanged. They do not send shell commands
or change PTY termios. Configure retains program OSC color overrides until
reset. Startup children remain gated through allocation, reader preparation
and tree publication; rejection does not execute the requested source. A pane
created by a client that sizes its panes (the app) stays gated until that
client attaches with the pane's real grid, or for one second, so the shell
draws its prompt once at the final size; CLI-created panes start at once.
Typed input is held by the server until the program takes the terminal, that
is turns off its line editing or echo as a shell's line editor does, or for
at most two seconds, so keys pressed while a shell starts are shown once by
the shell rather than echoed raw above its prompt and then again. Process
discovery ignores the child while it still carries the server's own image
between fork and exec, so a header never names the server as the program.
Shells the app bundle carries integration for (zsh through a Koi-owned
`ZDOTDIR` whose startup files run the user's own, fish through a vendor
configuration on `XDG_DATA_DIRS`) name each command themselves (OSC 7502 at
preexec, cleared by the OSC 133 prompt markers); that name is the program
until the prompt returns, and discovery then only tracks the directory.
Shell reports use the engine's streaming OSC callbacks, so command and prompt
markers remain ordered even when split across PTY reads.
Servers installed on remote machines carry no integration files, so there
discovery alone names programs. The app reads its bundled server's version at launch and reports
in Diagnostics and the machine picker when the running local server is
another build.

JSON `appearance` remains independent of app configuration: the CLI protocol
still accepts foreground, background and cursor colors. The app supplies its
fixed palette and configured history budget through `Wire.Appearance`.
JSON colors are six hex digits without `#`; `scrollbackMB` defaults to 32 and
accepts 0–1024, with zero disabling history. Public config
and Settings deliberately cap the range at 1–32 MiB for reliable reattachment,
with the same 32 MiB default. These are engine page estimates, not
hard total-memory or cross-client privacy guarantees. Old mirrors can impose
their own 32 MiB default, and all snapshots still obey the 64 MiB frame cap.

For a remote machine, SSH installs the server under `~/.local/share/koi/koi`
and obtains connection details. The app then uses the encrypted UDP link,
falling back to the SSH stdio relay if UDP is unavailable. While the relay
serves, the link is tried again every 30 seconds, except that a probe UDP
left unanswered is not repeated for ten minutes: each costs an SSH round
trip and a blocked port rarely opens within minutes. Bundled server
builds support Apple silicon macOS and x86_64 Linux. Setup commands have a
60-second deadline and retain at most 1 MiB each of stdout and stderr;
cancellation stops and reaps the local SSH process. See
[`remote.swift`](../src/app/remote.swift) and
[`link.zig`](../src/core/link.zig) for the connection implementation.

[`deviceicons.swift`](../src/app/deviceicons.swift) identifies machine icons
independently of session setup. A background profiler lookup extracts only
the reported Mac model family; remote lookups use the existing SSH options,
and Linux uses a generic server symbol. Lookups time out after 15 seconds,
coalesce per endpoint, and retain a validated symbol in layout metadata for
offline display. Removed profiles and state-directory changes invalidate late
results. No server update or protocol change is needed; views only read the
cache. Tests inject probes and never launch hardware or SSH lookups.

The app retries a lost pane or control connection with a capped backoff, and
at once when the local server's socket directory changes or the network
path changes, so a restarted server or a returning network is not left
waiting out a timer.
A pane reattaches by ID and restores a fresh snapshot; a control connection
gets the current tree. Detaching a workspace cancels retries and closes its
connections. This recovers transport interruptions while the server remains
alive; restarting the server still ends its shells.

Endpoint connections and server startup run away from the main actor. Late
results after detach are closed rather than installed. A view without settled
geometry attaches with zero dimensions, which leaves the server's creation
size intact; animation resize holds postpone only resizing, never output.
Successful commands send the subscribed caller a current tree immediately;
other watchers retain the short metadata debounce.

Input and output schedule a coalesced foreground-process and directory
sample after a short delay, at most once per 100 ms. Idle panes retain a
500 ms fallback. Process discovery runs outside the pane mutex; a generation
check rejects results invalidated by new input, OSC directory reports or
close. OSC title, directory and status reports update metadata during parsing.

## Layout and presentation

Pane cards are cached by terminal identity across tabs and pruned against the
live workspace mirrors. Pane motion seats the destination grid before the
reveal, then moves position and opacity rather than scaling glyphs or resizing
the PTY on every animation tick. A new split slides out from the pane it was
split from, opaque throughout: a translucent card would show the glass behind
it as a flash. Tabs, new or switched to, show at once. A display-paced clock can
retarget from the installed position. The `animation` setting selects `snappy`
(the default, 180 ms), `natural` (260 ms) or `off`; `off` and system Reduce
Motion settle transitions directly.

Pane headers default to 42 points high with 8-point split gaps; `compact-panes`
uses 32-point headers and 4-point gaps. `show-pane-headers` controls visibility.
Focused and unfocused pane outlines are always neutral, without an accent-border
setting. `focus-follows-mouse` optionally focuses panes under the pointer;
`fade-inactive-panes` optionally dims inactive terminal content. Both default off.

Sidebar motion keeps the rail and header stationary while panes cover them,
including clipped, noninteractive native traffic lights. Its current
`PaneTransitionShell` is a temporary static background around the destination
live grids: it fills exposed bands, preserves gaps and absorbs filler clicks
without storing terminal pixels. The window clock owns its lifetime and
reversal. Interactive sidebar resizing uses its own terminal resize hold
until release.

`SettingsWindow` in `settings.swift` is a fixed-size glass window without
traffic lights. It closes on focus loss or Command-W and ignores zoom/fullscreen
actions. Blur dismissal waits until focus settles so attached sheets and modal
save dialogs can keep their initiating Settings window. Its categories
are Appearance (the default), Terminal, Shortcuts, Machines & Server, Activity
and Advanced. Terminal's Text group owns font family, size and line height;
Terminal also contains cursor and input/session controls. Appearance contains
opacity, reduced transparency, motion, tab placement, pane headers, compact
spacing and inactive-pane fading. Font actions belong to Terminal in shortcut
lists and the palette; Toggle Sidebar and tab placement belong to Appearance.
The horizontal strip supports mouse
dragging, native two-finger scrolling and bounded arrow buttons, with no
keyboard category handlers. Search spans
categories; committed values reload through the app coordinator, while
unsaved drafts remain local to the Settings view. See
[Configuration](configuration.md) for the user-facing controls.

[`buttons.swift`](../src/app/buttons.swift) defines `Capsule`, Koi's continuous
9-point rounded rectangle for compact controls, and `SelectionSurface`, its
shared backing for Settings and Diagnostics categories. Tabs and collapsed groups
containing the selected tab use `GlassTabSurface` in `tabs.swift`: horizontal
selection keeps a translucent fill and faint rim; vertical selection adds a
subtle gradient over material, honoring Reduce Transparency. Palette
fields and results, prompt buttons and shortcut recorders use the same shape.
It adds no layout or motion. `theme.swift` supplies the fixed dark glass palette:
background `17171b` and foreground/cursor `e6e6ea`. `config.swift` retains
background opacity (default 0.85), motion and pane preferences, persisted in
the config file. Windows use dark appearance; the `reduce-transparency` setting
or macOS Reduce Transparency selects solid backing.

Left, top and right tab strips share [`tabinput.swift`](../src/app/tabinput.swift).
A tab is selected on mouse-down, as native tab bars do, so a click switches
as immediately as a shortcut; the native click count on the second press
recognizes a double-click rename without putting a multi-click recognizer
around the close button.
Rows stay in place during a drag; live target geometry provides an insertion
cue or highlights an existing group header. Release commits one move and
clears the gesture immediately. Escape cancels it. New groups are created
explicitly through the tab menu, while dropping on a named group joins it.
Vertical rails resize from their inner edge and share a saved width. Resizing
holds terminal dimensions until release so intermediate frames do not
repeatedly resize the shell.

Renderers share the immutable Metal device and pipeline. Per-pane engine
state and glyph atlases stay independent; unchanged font metrics survive
view reparenting. A failed drawable/presentation attempt retains its pending
frame for the next display tick. Main-thread output deliveries are bounded to
256 KiB or 64 events, with indivisible snapshots allowed alone, so streaming
output yields between deliveries. The focused pane draws output the moment it
arrives instead of waiting for that tick, which is up to one frame less
between a keystroke and its echo; other panes draw on the tick. Remote panes
predict typing locally (see `echo.swift`): the predicted cell is drawn on the
keystroke itself, before the round trip, and reconciled with the real echo. Each pane's display link pauses once a tick
finds nothing to draw, and wakes on output, input, a gesture or the window
being uncovered, so idle panes cost no frames. A blank initial snapshot suppresses the
cursor until the shell's first output or input, bounded at two seconds for a
shell that never prints; this does not delay shell startup or terminal output. While a pane is scrolled back, its
top padding and first row fade into the background so earlier output reads
as continuing under the header rather than being cut off at it; at the live
screen nothing is faded.

## Diagnostics

[`diagnosticswindow.swift`](../src/app/diagnosticswindow.swift) owns the glass
window's horizontal Overview, Connections, Rendering and Recent Issues
sections. `app.swift` wires Help and palette actions, snapshot providers and
explicit probes to the invoking window. Endpoint inspection is independent
of active-session selection and never connects, attaches panes or starts
processes. Refresh uses an existing control connection. A 1 Hz timer samples
only while visible; close/minimize invalidates it, and Pause skips automatic
snapshot updates. Copy/export uses the inspected snapshot's report.

Renderer counters are lock-protected and polled rather than published per
frame. They count committed submissions, successful completions, failures
and retry deferrals, with pending/in-flight state and drawable dimensions.
CPU timing covers assembly through commit, including drawable waits; GPU
execution uses valid timestamps from successful command completions. Atlas
and vertex-buffer allocation bytes count each live resource once, including
replaced resources still in flight. These are terminal-renderer measurements;
they do not measure GPU utilization, total process memory, WindowServer
composition or sidebar animation. Counter reset preserves in-flight ownership.

`DiagnosticIssues` keeps up to 100 sanitized, deduplicated app summaries.
Recent Issues merges them with retained errors from live attached renderers
and displays the newest 100. Clear History clears app summaries and hides
renderer issues predating the clear without touching log files. Reports
exclude raw logs and terminal text; opening the local server log requires
the explicit Open Local Server Log action. Copy/export shares the redacted
report formatter. Only a validated `major.minor.patch+` version with a
64-digit lowercase hex hash bypasses token scrubbing in the server-version
field, and only when it contains no configured host alias.

## Terminal text and activity

App mirrors handle OSC 52 text clipboard writes through the engine callback,
after snapshot restoration. Only the keyboard-focused pane in the active window
may copy a complete UTF-8 text value up to 1 MiB to the Mac pasteboard.
A clear request writes empty text; primary and
selection destinations are unsupported. Terminal clipboard reads are not exposed. Local
Shift-drag selection and Cmd-C remain independent of application-owned mouse
selections.
The mirror uses the engine's OSC boundaries to accept only OSC 52 writes.
Kitty clipboard transactions remain unsupported: they need acknowledged
server/client routing before they can change a client's clipboard.

[`accessibility.swift`](../src/app/accessibility.swift) builds a read-only AX
text document lazily, using UTF-16 indices and physical terminal rows across
screen and history. It maps wide cells and graphemes, visible ranges, cursor
and actual selection endpoints rather than searching for matching text.
Terminal mutations invalidate the document; observed accessibility changes
coalesce at four batches per second. Rendering does not build this document.
IME marked text remains a separate `NSTextInputClient` document and AX queries
cannot commit or replace terminal input.

Activity merges connected workspace snapshots by endpoint and pane identity.
Explicit `reportStatus` and legacy OSC 7501 reports coexist with output/process
inference; explicit reports are tied to foreground identity rather than a
permanent pane label. Notification delivery is injected, opt-in for blocked,
done and error transitions, and quiet while focused by default. Initial
observations and suppressed/repeated statuses produce no catch-up alerts.
Construction does not query or request notification authorization; a user
permission action requests it. Notification clicks resolve stable endpoint,
tab and pane IDs across existing windows, retrying for up to two seconds
during initial attachment. Stale targets never create connections or shells.
Optional agent skills are advisory single-file guidance, not lifecycle-hook
installation or guaranteed status delivery.

## Ownership and memory limits

Swift uses ARC; Zig and the engine handles have explicit owners. There is
no tracing garbage collector. Each terminal owns its engine state, each
renderer frees its render-state helpers, and each selection gesture retains
its terminal until its tracked references have been freed.

The embedded native library leaves alternate signal-stack ownership with
the host application, including when the host runs under a sanitizer.

A Swift link stream retains its link. Closing a native stream wakes readers
but keeps its pointer valid; the application releases its ownership exactly
once after its callers finish. The server unregisters a connection from
panes and watcher lists before releasing it. A pane stays allocated until
its child has been reaped, tree removal has finished and no connection or
command holds a pin. Removing it from the visible tree alone does not free it.

Slow consumers apply backpressure or are disconnected instead of growing
queues indefinitely. The principal limits are:

| Resource | Limit |
| --- | --- |
| Protocol payload | 64 MiB |
| Terminal grid | 1,048,576 cells |
| Scrollback per terminal | Default 32 MiB of engine pages; public config 1–32 MiB, JSON 0–1,024 MiB; snapshot limits still apply |
| Pending pane events | 8 MiB or 1,024 events; one larger frame may occupy an otherwise empty batch |
| App socket writes | 128 MiB and 4,096 pending writes |
| App link writes awaiting the worker | 64 MiB and 4,096 pending writes per stream |
| Server socket backlog | 16 MiB plus the current frame |
| Remote unsent data | 64 MiB per stream |
| Remote receive window | 4 MiB per stream; out-of-order storage is also bounded |
| Unreclaimed remote streams | 128 per link |
| Retained closed-stream records | 4,096 per link |

Remote app writes run on an ordered worker per link; keyboard handling never
waits for the native link mutex or packet encryption. The transport rotates
between streams as congestion credit becomes available, so a bulk stream
cannot always take the next available slot.

An application must release closed remote streams; awaiting FIN completion
continues to consume a stream slot. When old closed-stream records are
trimmed, unknown older IDs are ignored, including exceptionally late first
packets. Established streams are retained. These are resource policies, not
a change to version 6 framing.

Glyph-atlas eviction creates a fresh texture so in-flight GPU commands keep
their texture. Frame assembly pins one atlas generation and retries eviction
once. If a visible set exceeds the fixed atlas capacity, excess glyphs are
omitted for that frame rather than using stale UVs or allocating unlimited
textures.

## Storage

Layout metadata is cached per state directory. Selection is shown before
persistence, and rapid saves coalesce onto a serial utility queue. App
termination flushes the latest values after earlier writes.

| Data | Default location |
| --- | --- |
| Configuration | `~/.config/koi/config` |
| Layout and machine metadata | `~/.local/state/koi/layout.json` |
| Named project recipes | `~/.local/state/koi/projects.json` |
| Server log | `~/.local/state/koi/server.log` |
| Socket and server lock | `$TMPDIR/koi`, or `/tmp/koi` when unset |
| macOS window preferences, palette recents and manual update source | The app's UserDefaults domain |

`XDG_CONFIG_HOME`, `XDG_STATE_HOME` and `XDG_RUNTIME_DIR` override their
respective directories. `KOI_DIR` puts configuration, state and runtime
files together in one directory; it does not relocate UserDefaults.
Long socket paths use `/tmp/koi-<uid>/server-<version>.sock`. State, runtime
and SSH control directories must be private, user-owned directories; invalid
locations are rejected without changing their permissions.

Project recipes whitelist names, directories, tab/group order, topology and
relative split weights, with fresh IDs on restore. The PTY launcher uses `/` if a saved directory cannot be entered.
Startup source is only an explicit per-pane recipe field; the app's save action does not infer it
from processes. Recipes contain no terminal snapshots or process backups.
Restore waits for watcher-confirmed topology and weights and selects the
first new tab only after success. Failure stops further work, preserves
existing jobs and leaves newly created tabs/helpers for inspection. The app
requires `splitCwd` and `resizeSplitWeights` before restoring a layout.

Support actions stay with their feature owners: updates have no default feed
or startup fetch and open release pages only after manual checks;
diagnostics format allowlisted facts without reading logs, terminal contents
or raw config values. Copy and save-panel export use the same redacted
report. CLI and Codex/Claude skill installation
mutate files only from user clicks. See [Configuration](configuration.md)
and [CLI](cli.md) for their destinations and controls.

Koid uses `KOI_DIR=~/.local/state/koid` and a separate bundle identifier,
`com.fschrhunt.koid`, keeping its sessions and macOS preferences apart from
Koi. Its screenshot and UI-preview receivers are enabled by the `KOID`
compile flag and excluded from production builds. See
[Contributing](../CONTRIBUTING.md) for the development workflow.
