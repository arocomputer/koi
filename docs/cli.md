# CLI reference

The `koi` executable is both the server and its command-line client. Koi
adds its directory to each pane's `PATH`. Outside a pane, the bundled Mac
CLI is at `Koi.app/Contents/Resources/koi`; source builds also produce
`build/core/koi`. During development, use `scripts/koid koi …` to address
the separate Koid server.

**Install CLI…** in Settings → Advanced creates `~/.local/bin/koi`, a wrapper
that invokes the current bundle's executable. Add `~/.local/bin` to your
shell's `PATH` if needed; Koi does not edit it. Koid installs
`~/.local/bin/koid-cli` instead and pins `KOI_DIR` to `~/.local/state/koid`.
Installation happens only on a click, copies no binary, and preserves an
existing foreign or edited wrapper. Moving the app can invalidate its wrapper.

## Commands

| Command | Behavior |
| --- | --- |
| `koi ls [--json]` | List tabs and groups in order; `--json` prints the server's tree as sent, including tab names |
| `koi new [--cwd DIR] [--command SOURCE]` | Create a tab and print its tab ID |
| `koi send TARGET TEXT...` | Send text to the target tab's first pane |
| `koi capture [TARGET]` | Print the first pane's screen and scrollback |
| `koi split [TARGET] [--down \| --right] [--cwd DIR] [--command SOURCE]` | Split right by default, or down; print the new pane ID |
| `koi do SOURCE` | Run Lua source with the `koi` scripting table; see [Scripting](#scripting) |
| `koi run FILE [ARG...]` | Run a Lua script file; `ARG...` arrive in the global `arg` |
| `koi status [PANE] STATE` | Report `working`, `blocked`, `done`, `error` or `idle` for an exact pane ID |
| `koi api [OP]` | Print the commands the server accepts as JSON: every operation with a summary and the capability to probe for, and every command field with its type and values. With `OP`, only that operation. Reads the binary, so it works without a running server |
| `koi info [--json]` | Report the running server's version, PID, protocol, uptime, transports and capabilities |
| `koi version` | Print this binary's own version, without contacting a server |
| `koi clear [TARGET]` | Erase retained scrollback, preserving the visible screen and modes |
| `koi reset [TARGET]` | Reset the terminal engine's screen, history, modes and parser |
| `koi close [TARGET]` | End the pane with that ID, or the target tab's first pane |
| `koi help` or `koi --help` | Print command usage |

`send` joins its text arguments with spaces and converts literal `\n` to
Enter. For example, inside an existing Koi session:

```sh
koi ls
koi info --json
koi new --cwd "$PWD"
koi split --down --cwd "$PWD" --command 'printf "%s\n" "new shell"; exec /bin/zsh -l'
koi send 1 'echo hello\n'
koi capture 1
koi status working
koi status done
```

`--command` is shell source passed intact to the login shell with `-c`.
Quote it as one argument so pipelines, quoting and expansions belong to
that new shell. Without it, creation starts an interactive login shell.
An empty command is rejected; when the command exits, its pane can end.
`--cwd` chooses the new shell's initial directory. Without an explicit
directory, a split inherits its source pane's directory; `new` uses the
server's home directory. Inside a pane, `new` uses `KOI_TAB` for tab placement,
not directory inheritance. If the requested directory cannot be entered,
the PTY launcher falls back to `/`. The CLI does not read the app's `startup-command` setting.

Clear and reset run no shell command and preserve the process, PTY, grid
size and configured appearance/history budget. Reset also clears terminal
metadata reports, but does not repair the PTY's termios settings or restart
the shell. The server broadcasts the resulting snapshot to attached clients.
There is no CLI `configure` subcommand: theme defaults and scrollback
configuration use JSON `configurePane` through the control protocol.

## Describing the commands

`koi api` is for scripts and agents that need the command vocabulary without
reading the source:

```sh
koi api reportStatus     # one operation, with the full field list
koi api | jq '.operations[].op'
```

The fields come from the same type the server decodes, so they cannot drift
from what it accepts. They are shared by all operations; the field list does
not say which operations read which, and an operation ignores fields it does not
use. Probe an operation's `capability` with `koi info --json` before sending it
to a server that may be older.

## Scripting

`koi do` and `koi run` run Lua 5.4 with a global `koi` table. Scripts drive the
same commands as the shell, so there is nothing to learn twice:

```lua
-- koi run build.lua
local tab = koi.new { cwd = os.getenv("HOME") .. "/src/app", command = "make watch" }
koi.wait(tab, "Build succeeded", 120)       -- nil on timeout
koi.split(tab, { direction = "down", command = "tail -f server.log" })
for _, item in ipairs(koi.ls().items) do print(item.tab and item.tab._0.id) end
```

| Function | Does |
| --- | --- |
| `koi.run(...)` | Runs `koi ...` and returns `ok, stdout, exit_status` |
| `koi.json(text)` | Decodes JSON; `null` becomes `nil` |
| `koi.sleep(seconds)` | Waits |
| `koi.ls()` | The server's tree, decoded from `koi ls --json` |
| `koi.new{cwd, command}` | New tab; returns its id |
| `koi.split(target, {direction, cwd, command})` | Splits; returns the new pane's id |
| `koi.send(target, text)`, `koi.capture(target)`, `koi.close(target)`, `koi.status(state)` | The commands of the same names |
| `koi.wait(target, pattern, timeout)` | Polls a pane until a Lua pattern matches; returns the match, or `nil` after `timeout` seconds (default 30). Safe right after `koi.new` |

The helpers raise an error naming the failed command. A script that raises, or
cannot be loaded, prints `koi: MESSAGE` and exits 1; one that finishes exits 0,
and `os.exit(n)` chooses the status. The standard libraries are the plain ones
(base, string, table, math, utf8, coroutine, io, os). `require`, `package` and
C modules are not available, and `debug` is left out. A script runs with your
own authority, like a shell script you chose to run: it can run programs with
`os.execute` and `io.popen`. It reaches the server only through the `koi` commands,
so it needs the same `KOI_DIR` the commands would.

This is a way to script the multiplexer from outside. It has no events, timers or
`init.lua` of its own.

## Targets and pane selection

A tab target is its full ID, an ID suffix of at least four characters, or a
position starting at 1. Use full IDs in scripts: positions change when tabs
are reordered. Suffixes should be unique; the resolver takes the last match
when several IDs share a suffix.

| Commands | Explicit target | Omitted target |
| --- | --- | --- |
| `send`, `capture`, `close` | Exact pane ID, or tab target selecting its first pane | `capture`/`close` use `$KOI_TAB`; `send` requires a target |
| `split`, `clear`, `reset` | Exact pane ID, or tab target selecting its first pane | `$KOI_PANE`, then `$KOI_TAB` |
| `status` | Exact pane ID only | `$KOI_PANE` required |

Koi sets `KOI_TAB` and `KOI_PANE` in its shells. Preserve their server context,
including `KOI_DIR`, when reporting status from tools. Explicit status reports
reach the server directly and do not depend on tool stdout reaching the PTY.
Reports describe the foreground program; they are cleared when its identity
changes. Advisory agent skills do not guarantee lifecycle reporting.

Closing one pane removes the whole tab only when it was the last pane.
To close every pane in a tab, use **Close Tab** in the app or palette
(⇧⌘W by default). The CLI's `close` command ends one pane at a time: the
pane whose ID it is given, or a tab's first pane.

## Running-server compatibility

`info` describes the answering process, even after the executable on disk
has been rebuilt. Its version includes a build fingerprint; do not substitute
the app bundle version for server identity. JSON also exposes the exact
capability names in [Architecture](architecture.md#connections-and-protocol).

The CLI probes `serverInfo` before clear/reset, status, startup source, and
explicit split-directory requests. Older protocol-v6 servers may lack these
capabilities and silently ignore unknown fields. Unsupported requests fail
before the mutation and leave existing sessions intact. A plain `new --cwd`
and split without new options retain their older behavior. Rebuilding or
installing a binary does not replace an already running server; restarting
that server ends its shells.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Operation, capability check or response failed |
| 2 | Invalid command line |
| 3 | Target pane or tab could not be resolved |
| 4 | Server could not be reached |

A nonexistent exact pane passed to a control operation can instead produce
code 1 from the server's error response. `status` without an explicit pane
or `KOI_PANE` returns 2. Running `koi` without a command prints usage and
returns 2.

The app's remote setup also uses `koi --offer` and `koi --stdio` internally.
Their transport protocol is described in [Architecture](architecture.md);
they are not additional interactive tab commands. The command parser and
help text live in [`cli.zig`](../src/core/cli.zig).
