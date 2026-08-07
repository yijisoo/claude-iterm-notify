# Spec: Tab-only notification targeting

Status: proposed
Scope: `notify.sh` (notification flow + `--focus` click callback)

## Background

`notify.sh` fires a macOS notification when a Claude Code session needs
attention, and on click takes the user to the iTerm2 tab running that session.
It supports three terminal topologies today:

1. Claude running directly in an iTerm2 tab.
2. Claude running inside a tmux session shown in a tab.
3. Claude in a *detached* tmux session — handled by attaching/`switch-client`.

## Problem

Topology 3 grew a pile of edge-case logic (`tmux has-session`,
`tmux switch-client`, open-new-tab fallback, click-time `list-clients`
resolution). It produced two bad behaviors:

- **Tab proliferation**: clicking a notification for a detached session opened
  a new tab every time.
- **Tab hijacking**: the `switch-client` reuse pointed an *arbitrary* existing
  tmux tab at the notification's session, silently replacing whatever that tab
  was showing (e.g. a code-review tab became a stress-test tab).

The root cause is OMC's usage pattern, clarified with the user:

- An **active** `omc claude` run is **1:1 with one iTerm2 tab**. There is no
  legitimate case where an active parent run lacks a tab.
- The tab-less tmux sessions that fire notifications are **not** parents we
  care about. They are:
  - **OMC team workers / subagents** — separate `claude` processes in their own
    tmux sessions, with no tab of their own.
  - **Stale parallel runs** — old `omc-…-<timestamp>` sessions left detached.

Claude Code already distinguishes `Stop` (parent) from `SubagentStop`; the hook
is on `Stop` only, so internal Task subagents never notify. The remaining noise
is entirely **sessions that have no iTerm2 tab**.

## The rule

> **Notify only when the firing session is shown in a live iTerm2 tab.**
> Resolve that tab at notification time and target it directly. A tmux session
> with no attached client (worker / subagent / stale run) produces **no
> notification**.

This removes the "detached" case entirely — we never notify for a tab-less
session, so there is never an ambiguous "which tab?" decision at click time.

## Behavior

| Firing context | Has an iTerm2 tab? | Notification | Click |
|---|---|---|---|
| Claude directly in an iTerm2 tab | yes (the tab itself) | fire, target = that tab's tty | focus the tab |
| tmux session attached to a tab | yes (the client) | fire, target = client tty | focus the tab |
| tmux session with **no** client (worker / detached / stale) | no | **skipped** | n/a |

Notes:
- "Has a tab" for the tmux path = the session has **at least one attached
  client**; the client's tty *is* the iTerm2 session's tty.
- The notification can fire even when its tab is not frontmost (attached ≠
  frontmost). The existing "don't notify the session you're actively watching"
  suppression and the per-session debounce are unchanged and still apply.

## Implementation changes

Target is resolved **at notification time** as a `tty:` value; the durable
`tmux:` scheme and all click-time tmux logic are removed.

Notification flow (`identify_target` becomes "find the iTerm tab tty"):

1. `raw_tty = get_tty` (walk the process tree to the controlling tty).
2. If `raw_tty` is a **tmux pane** (`tmux list-panes -a` match):
   - `session` = that pane's session name.
   - `client_tty` = first attached client of `session` (`tmux list-clients`).
   - If `client_tty` is empty → **no tab → exit 0 without notifying.**
   - Else `TAB_TTY = client_tty`; subtitle = the pane title.
3. Else (`raw_tty` is not a tmux pane → Claude is directly in the terminal):
   - `TAB_TTY = raw_tty`; subtitle = the iTerm2 session name (only queried if
     iTerm2 is running).
4. `TARGET = "tty:$TAB_TTY"`.

Click callback shrinks to one branch:

```
--focus tty:<path>  →  focus_iterm_tty <path>
```

**Removed**: the `tmux:` target scheme, `open_iterm_tab`, click-time
`tmux list-clients` / `has-session` / `switch-client`, and the new-tab and
"reuse a client" branches. `as_escape` was removed at this point too (no
command was fed to iTerm2 in the targeting path); it was later reintroduced
(`55d3fe0`) for the opt-in `SessionStart` title-setting hook, which does feed
a command to iTerm2 — see the note under Review refinements below.
`sq_escape` is still used for the `--focus` callback argument.

## Edge cases

- **Non-iTerm2 terminal directly** (Terminal.app, VS Code): not a tmux pane →
  step 3 → notify with `tty:raw_tty`. The notification still fires (useful);
  clicking is a harmless no-op since no iTerm2 session has that tty. We do not
  suppress here — the notification's value is the alert itself.
- **tmux session with multiple clients**: pick the first; any of its tabs is a
  correct target.
- **Detached parent** (user closed the tab but the run continues): no client →
  skipped. Acceptable — there is no tab to focus, and per the usage model an
  active run keeps its tab.
- **tmux server unavailable** mid-lookup: lookups are guarded (`|| true`); a
  failed `list-panes` means "not a tmux pane" → falls to step 3.

## Trade-offs

- Backgrounded/detached sessions no longer notify. Accepted: this is exactly
  "ignore workers / subagents," and there is no tab to land on anyway.
- We resolve the tab at notification time, not click time. If the tab detaches
  between notify and click, the click is a no-op rather than chasing the
  session. Accepted for the large reduction in complexity.

## Review refinements (from expert review)

- **Debounce key stays durable.** `debounce_ok` must key on a stable id, not on
  the `tty:` target (which changes if the user reattaches the session to a
  different tab). Key on the **tmux session name** for the tmux path, and on
  `raw_tty` for the direct path. (Target and debounce key are now separate
  values.)
- **Skip early.** The "no client → don't notify" case must `exit 0`
  *before* the watching-suppression and debounce checks, and must **not** fall
  through to the old `-activate` no-target branch.
- **Keep `sq_escape`** for the `--focus '<target>'` callback string (defensive;
  costs nothing). **Delete** `as_escape` and `open_iterm_tab` at this point
  (no command is fed to iTerm2 in the targeting/click path).
  **Update (2026-07-24, `55d3fe0`):** `as_escape` was reintroduced for the
  opt-in `SessionStart` → `notify.sh title` hook (`notify.sh:107-112`, used at
  `notify.sh:492`), which sets the iTerm2 session name to the project's
  basename via `set name of s to "..."` — a real command fed to iTerm2, so
  the string must be AppleScript-escaped. `open_iterm_tab` remains deleted;
  only `as_escape` came back.
- Keep `|| true` on every `tmux list-*` pipeline (guards `set -euo pipefail`).
- Update the header comment block — drop topology 3 and the `tmux:` callback.
- `user_is_watching` now receives the resolved tab tty (first client for the
  tmux path); suppression compares the frontmost tab against that tty.

## Test plan

Unit (mocked `ps` / `tmux` / `osascript` / `terminal-notifier`):

1. Direct tty → notify, `TARGET=tty:<raw_tty>`.
2. tmux pane with an attached client → notify, `TARGET=tty:<client_tty>`,
   subtitle = pane title.
3. tmux pane with **no** client → **no** `terminal-notifier` call (skipped).
4. `--focus tty:X` → selects the tab with tty X (one AppleScript).
5. Watching-suppression and debounce still apply on the `tty:` target.
6. No remaining references to `tmux:` / `switch-client` / `create tab` in the
   click path.
