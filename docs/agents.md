# Agent integrations

Koi does not maintain a directory of agent identities. The program catalog supplies
icons; an integration explicitly declares its role with `koi agent`. An unfamiliar
agent works without a Koi catalog update. Running `koi status done` or naming an
ordinary process `claude` does not enable agent completion notifications.

## Custom integrations

Check `koi info --json` for the running server's `agentSessions` capability. From
the agent's Koi pane, preserve `KOI_PANE` and `KOI_DIR` and report:

```sh
koi agent my-agent working session-123 turn-1
koi agent my-agent blocked session-123 turn-1
koi agent my-agent done session-123 turn-1
koi agent my-agent working session-123 turn-2
```

States are `working`, `blocked`, `done`, `error` and `idle`. Session and turn keys
are integration-generated opaque identifiers, at most 128 bytes, never prompts
or secrets. Name and adapter must stay consistent within a session. Koi generates
its own session identity and run number and binds them to the foreground process
group. A foreground process change or shell prompt ends that registration.
Process-name guesses do not change an active registration. An exec-based pane
startup is supported too.

If the integration has no turn key, omit it. Koi starts a new run when `working`
follows `idle`, `done` or `error`. With turn keys, a new key starts a new run;
reports from the last 16 retired turns are rejected. Repeated identical reports
do not create events. A registration must begin with `working` or
`idle`. These reports are local integration metadata, not an authentication boundary.

Each pane retains its latest 64 events with an epoch and sequence number. The app
replays them across coalesced updates and short disconnects, even if a program
has already returned to the shell. It considers only the latest session/run,
so earlier turns cannot alert for later work. First observations and server
restarts establish silent baselines. An expired journal establishes a new baseline
and shows an Activity warning rather than inventing missing transitions. Notification
preferences and viewed-pane suppression still apply. Reading a pane consumes its
unread completion; replaying the same event never makes it unread again.

## Provider adapters

Advanced settings can install separate adapters for Claude Code and Codex. The
commands are `koi agent hook claude EVENT` and `koi agent hook codex EVENT`, with
the provider's JSON hook payload on stdin. The CLI validates `hook_event_name`
and `session_id`, and Codex turn-scoped reports require `turn_id`. Subagent
reports with `agent_id` are ignored so they cannot complete the parent's pane.
Only identity and status reach Koi; prompts and transcript paths are not forwarded.
Input is capped at 8 MiB. Hook commands always exit successfully to their provider;
unsupported payloads produce no lifecycle event and do not interrupt a turn.

- `claude-hooks-v1` uses [Claude Code command hooks](https://code.claude.com/docs/en/hooks):
  SessionStart/SessionEnd, UserPromptSubmit, PostToolUse, PermissionRequest, Stop
  and StopFailure. Claude has no public turn ID, so each UserPromptSubmit explicitly starts a run,
  including when a prior turn was interrupted before reporting its end. A
  SessionStart with `source` `compact` is ignored: Claude sends it after
  compacting, which can happen mid-turn, and it does not change the turn's state.
- `codex-hooks-v1` follows [Codex's command-input schemas](https://github.com/openai/codex/tree/main/codex-rs/hooks/schema/generated):
  SessionStart/SessionEnd, UserPromptSubmit, PostToolUse, PermissionRequest, Stop
  and Interrupt. Turn-scoped events retain Codex's turn ID. Older Codex releases
  without these hooks/fields are not verified by a matching configuration file.

**Configured** means Koi's entries are present in the settings file. It does not
claim support for an arbitrary installed provider version. Runtime schema validation
checks capabilities on actual reports; Activity settings show each active adapter
and its last accepted report time. No reports means unverified, not healthy. The
advisory skill is separate and cannot guarantee reports. Existing hooks need
**Update** once to use these adapters. Install/remove preserve other hooks and
keep the first `.koi-backup`.

## Pane launch environments

A long-lived daemon's starter may itself be an agent. New panes inherit the
server's environment, minus the session markers a running Claude Code puts in
its children's environment (`CLAUDECODE`, `CLAUDE_PID`, `CLAUDE_CODE_SESSION*`
and similar), so a `claude` started in a pane is not mistaken for a nested child
session. Settings such as `CLAUDE_CONFIG_DIR` stay. Terminal identity and shell
integration variables are rebuilt for each pane.
