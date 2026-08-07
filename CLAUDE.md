# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single dependency-free bash script (`notify.sh`) installed as a Claude Code hook. It fires native macOS notifications via `terminal-notifier` when Claude needs attention (stop / permission / question), and click-to-focus jumps to the exact iTerm2 tab that session is running in — including sessions nested inside tmux (e.g. oh-my-claudecode agent orchestration). Fork of `stevemeisner/claude-iterm-notify` (remote `origin`); pushes go to `fork` (`yijisoo/claude-iterm-notify`).

No build step, no package manager, no runtime dependencies beyond bash/coreutils + `terminal-notifier` + optional `tmux`.

## Commands

```bash
./tests/run.sh                    # run all test suites
./tests/run.sh test_notify.sh     # run one suite (test_notify.sh | test_install.sh)
```

There is no lint/build/typecheck target — this is pure bash. When editing `notify.sh`, `install.sh`, or `uninstall.sh`, always re-run the full test suite before considering a change done.

```bash
./install.sh                      # copies notify.sh to ~/.claude/hooks/, merges hook entries into ~/.claude/settings.json
./uninstall.sh                    # reverses install.sh, removes the event log
~/.claude/hooks/notify.sh --report [days]   # summarize the local event log (default 7 days)
```

## Architecture

### The core rule

`notify.sh` (see header comment + `docs/notification-targeting.md` for the full design rationale) resolves, per invocation, whether the firing session currently has a live iTerm2 tab to land on — and only notifies if so:

1. Walk up the process tree from the hook's own pid (`get_tty`) to find the controlling tty.
2. If that tty is a **tmux pane** (`tmux list-panes -a`), find the tmux **client** attached to that pane's session (`tmux list-clients`). No attached client → this is a tab-less worker/subagent/stale run → `stop` events are skipped outright (`TARGET=SKIP`).
3. Otherwise the tty belongs directly to an iTerm2 tab; target that tty.

Target resolution happens **at notification time**, not click time — there is no durable `tmux:` scheme, just a `tty:` string. The click callback (`notify.sh --focus tty:<path>`) does a single AppleScript walk over iTerm2 windows/tabs/sessions to find and select the matching tty.

### Layered suppression before a notification actually fires

Each layer below is a separate, independently-testable gate in `notify.sh`, checked in this order for a `stop` event:

1. **Tab-less skip** — `TARGET=SKIP` (tmux session with no attached client) → exit immediately, no notification. Permission/Question events are exempt (a worker blocked on approval is genuinely stuck), so they still notify without a click target.
2. **Agent-team worker suppression** (`is_agent_worker`) — sessions launched as `claude --agent-id <agent>@<session>` are workers; their `stop` is the orchestrator's business, not the user's. Detected by walking process ancestry (depth-capped) for the `--agent-id` flag. Override: `NOTIFY_AGENT_STOPS=1`.
3. **Idle-gating** (`has_spinner` / hold-and-poll) — Claude Code titles a working tab with a braille-spinner glyph and an idle one with `✳`. A `stop` whose tab title still shows the spinner is a mid-work turn end (e.g. subagents still running): it's held, and a backgrounded watcher subshell re-polls the title every `NOTIFY_HOLD_POLL_SECONDS` until it goes idle, then delivers. The newest stop for a session owns the hold token, so a burst of intermediate stops collapses into one delivery.
4. **Busy heartbeat** — if a held session stays busy for a full `NOTIFY_HOLD_MAX_SECONDS` (default 600s), the watcher sends a truthful "Still working" ping and re-arms the clock (the clock is *not* reset by newer superseding stops — that would let a fast-cycling loop push the deadline forever).
5. **Watching-suppression** (`user_is_watching`) — skip if iTerm2 is frontmost and already showing the firing tab. Override: `NOTIFY_ALWAYS=1`.
6. **Debounce** (`debounce_ok`) — repeat `stop` notifications for the same session are throttled to one per `NOTIFY_DEBOUNCE_SECONDS` (default 1200s), keyed on a **durable** identity (tmux session name, or raw tty for direct sessions) rather than the resolved tab target, so it survives reattachment to a different tab. Permission/Question are never debounced.

All of these gates fail **safe and positive-match-only**: if a future Claude Code renames a flag or glyph, the gate simply stops engaging and behavior reverts to notify-immediately (late is acceptable, silently dropped is not).

### Stale-notification retraction

Every notification is tagged with a `-group` id derived from the session's durable debounce key. On *every* hook invocation (before deciding whether this new event itself warrants a notification), `clear_stale_notification` checks whether that session has an outstanding "live" marker and, if so, removes it from Notification Center via `terminal-notifier -remove` and logs a `retract` event. This catches the case where the user resolves a permission/question prompt directly at the terminal (not by clicking) and the session's next hook firing doesn't itself produce a new notification (held or debounced) — without this, the stale banner would sit there until whenever the next delivery happens to occur.

### Event log

Every hook invocation — delivered, held, debounced, skipped, retracted — appends one TSV line to `~/.local/state/claude-iterm-notify/events.tsv` (`event_log` function). This is the ground truth for `--report` and the primary tool for diagnosing notification noise; when changing any suppression logic, check that the corresponding outcome string (`notified`/`held`/`heartbeat`/`skip_no_tab`/`skip_watching`/`skip_agent_worker`/`debounced`) is still being logged correctly. Size-capped with one `.old` generation kept; disable via `NOTIFY_EVENT_LOG=0`.

### Tab-title hook (opt-in)

A separate `SessionStart` → `notify.sh title` invocation sets the tab title (tmux pane title or iTerm2 session name) to the project's basename, but only when `NOTIFY_SET_TITLE=1`. This is the one place the script *writes* terminal state rather than just reading it, and it exists specifically because Claude Code's own `sessionTitle` hook output has an undocumented effect on the real terminal — this hook doesn't depend on that at all, it sets the title directly via primitives used elsewhere in the script.

### install.sh / uninstall.sh

Both use an inline `python3` heredoc to safely merge/remove hook entries in `~/.claude/settings.json` — never regex/sed on the JSON. Merges are additive and idempotent (dedup by exact command string) and write atomically (temp file + `os.replace`); a pre-existing `settings.json` with invalid JSON aborts rather than being overwritten.

## Testing conventions

Pure bash, no `bats`, no external test framework (`tests/lib.sh` + `tests/run.sh` + `tests/test_*.sh`). Tests run `notify.sh`/`install.sh`/`uninstall.sh` as real subprocesses:

- `mock <name> <body>` (in `tests/lib.sh`) writes a fake binary into a per-test sandbox `$MOCKBIN` that records its args/stdin before running `<body>` — used to shadow `tmux`, `osascript`, `terminal-notifier`, `ps`.
- `run_notify` invokes `notify.sh` with `NOTIFY_TEST=1` (skips the real Homebrew `PATH` prepend so mocks on `PATH` take effect) plus sandboxed `HOME`, debounce dir, and short hold/poll intervals for fast tests.
- `mock_calls` / `mock_args` / `mock_sends` (sends = calls containing `-title`, i.e. actual notification deliveries, distinct from `-remove`/`--focus` housekeeping calls) / `mock_stdin` inspect what a mock recorded.
- Tests that touch the idle-gating background watcher subshell need to actually wait for it (short `NOTIFY_HOLD_POLL_SECONDS`/`NOTIFY_HOLD_MAX_SECONDS` from `run_notify`'s defaults) rather than assert synchronously.

When adding new behavior to `notify.sh`, add both the event-log outcome and a test asserting it in `tests/test_notify.sh`, following the existing `test_case "..."` / `assert_*` pattern grouped under a `# ── section ──` comment.

## Design docs

`docs/notification-targeting.md` is a proposal-style spec for the tab-resolution rule above — read it before changing `resolve_tab`, the tmux/iTerm2 targeting logic, or the `--focus` callback; it documents the prior (removed) `tmux:` targeting scheme and why it was replaced, which explains several things in the current code that would otherwise look under-engineered (e.g. no reconnect/reattach logic on click).

`TODOS.md` tracks evaluated-but-not-yet-adopted Claude Code hook surfaces (e.g. `MessageDisplay` for richer stop-notification bodies, blocked on an undocumented contract) — check it before proposing a new hook integration, since some have already been investigated and explicitly deferred with reasons recorded.
