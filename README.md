# Claude Code iTerm2 Notifications

Native macOS notifications when [Claude Code](https://docs.anthropic.com/en/docs/claude-code) needs your attention, with click-to-focus that takes you to the exact iTerm2 tab — including sessions running inside **tmux** (e.g. [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) orchestration).

## What You Get

| Event | Notification |
|-------|-------------|
| Claude finishes responding | **ProjectName** — "Ready for input" |
| Claude needs tool permission | **ProjectName — Permission** — the permission message |
| Claude asks you a question | **ProjectName — Question** — the question text |

- **Subtitle** shows what Claude was doing (the iTerm2 session name, or the tmux pane title for tmux sessions).
- **Click** switches to the correct iTerm2 tab — across multiple windows, and across tmux attach/detach.
- **No nagging**: notifications are suppressed for a session you're already looking at, and rapid "stop" events (OMC loop modes) are debounced.
- **No mid-work pings**: a stop that fires while the session is still visibly working (subagents running) is held and delivered when the session actually goes idle, and agent-team worker sessions don't ping at all when they finish.

## Requirements

- macOS
- [iTerm2](https://iterm2.com)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- [Homebrew](https://brew.sh) (for installing terminal-notifier)

> Optional: if you happen to run Claude inside **tmux** (e.g. via OMC), the script uses `tmux` to map the session back to its tab. It's not required for plain iTerm2 usage.

## Install

```bash
git clone https://github.com/yijisoo/claude-iterm-notify.git
cd claude-iterm-notify
./install.sh
```

This will:
1. Install `terminal-notifier` via Homebrew (if not already installed)
2. Copy the hook script to `~/.claude/hooks/`
3. Add notification hooks to `~/.claude/settings.json` (without touching your other settings)

Then **restart Claude Code** to activate.

The first notification will prompt you for macOS notification permission. Grant it in **System Settings > Notifications > terminal-notifier**.

## Uninstall

```bash
cd claude-iterm-notify
./uninstall.sh
```

Removes the hook script and this tool's hook entries from your settings (other hooks are left intact). Optionally uninstalls terminal-notifier.

## How It Works

Claude Code's [hook system](https://docs.anthropic.com/en/docs/claude-code/hooks) runs `notify.sh` on specific events. Rather than relying on `ITERM_SESSION_ID` (which is unreliable inside tmux), the script identifies the session by its **controlling tty** and resolves the focusable tab **at click time**, because tab↔session attachment is dynamic.

The guiding rule: **notify only when the firing session is shown in a live iTerm2 tab, and target that tab directly.** See [docs/notification-targeting.md](docs/notification-targeting.md) for the full design.

**When a notification fires:**
1. Read the hook's JSON payload from stdin (working directory → project name, message, etc.).
2. Walk up the process tree to find the controlling tty of the `claude` process.
3. Resolve the iTerm2 tab:
   - tty is a **tmux pane** → find the tab attached to that pane's session; subtitle = pane title. If the session has **no attached tab** (an OMC worker/subagent or a stale, detached run), **do not notify** — there's nothing to land on.
   - otherwise → Claude is **directly in an iTerm2 tab**; target that tty, subtitle = iTerm2 session name.
4. Skip if you're already watching that tab, or if it pinged recently (debounce).
5. Otherwise fire `terminal-notifier` with a `tty:` click callback.

**When you click:** focus the iTerm2 tab with that tty.

```
Claude Code hook fires
  → notify.sh resolves the iTerm2 tab for the session (tty)
  → tab-less tmux session (worker/subagent) → no notification
  → agent-team worker session (claude --agent-id) → stop not notified
  → tab title still shows the working spinner → held until the session idles
  → suppressed if you're already watching that tab
  → debounced if it pinged recently (keyed on the durable session name)
  → terminal-notifier shows the notification
  → you click → notify.sh --focus selects that tab
```

## Hooks Configured

| Hook Event | Matcher | What fires it |
|-----------|---------|---------------|
| `Stop` | — | Claude finished responding |
| `Notification` | `permission_prompt` | Claude needs tool approval |
| `Notification` | `elicitation_dialog` | Claude is asking a question |

## tmux & OMC

If Claude runs inside a tmux session (as [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) does — one tmux session per agent), the tab you see is just a *client* attached to that session. `notify.sh` maps `pane tty → tmux session → attached client tty → iTerm2 tab`, so click-to-focus lands on the right tab.

Sessions with **no attached tab** — OMC background workers/subagents, or stale runs you've moved on from — are intentionally **not** notified: there is no tab to take you to, and an active run always has its tab. This keeps notifications tied to things you can actually click into, and avoids spawning or hijacking tabs.

`tmux` is found even from terminal-notifier's minimal-PATH click callback (the script prepends Homebrew's bin).

## Subagents & Mid-Work Stops

Claude Code fires the `Stop` hook at **every** turn end — including intermediate ones, when the main agent pauses while background subagents are still running.
There is no documented payload field distinguishing those from the final "all work done, summary written" stop, so this tool uses two empirical mechanisms:

**Worker suppression.**
Sessions spawned as agent-team workers run `claude --agent-id <agent>@<session>`; sessions you drive don't.
A `stop` from a worker session is suppressed (logged as `skip_agent_worker`) — its "done" is the orchestrator's business.
Permission/Question prompts from workers still notify, because a worker blocked on approval is stuck until you act.
Set `NOTIFY_AGENT_STOPS=1` to restore worker stop notifications.

**Idle-gating.**
Claude Code titles a working session with a braille-dot spinner frame (⠐, ⠂, …) and an idle one with `✳`.
A stop whose tab title still shows a spinner is a mid-work turn end: it is *held* (logged as `held`) and a small watcher re-checks the title every `NOTIFY_HOLD_POLL_SECONDS` until the session goes idle, then delivers — re-checking "are you already watching" at delivery time.
The newest stop for a session owns the hold, so a burst of intermediate stops collapses into one notification at the true end; loop modes (ralph & co.) likewise coalesce to a single ping when the loop finishes.

Both mechanisms hold or suppress only on a **positive** match, so they fail safe: if a future Claude Code changes the title glyphs or the `--agent-id` flag, the gate simply never engages and behavior reverts to notify-immediately — a notification can be late (capped by `NOTIFY_HOLD_MAX_SECONDS`), never silently lost.
The event log below doubles as the canary: if mid-work deliveries reappear after a Claude Code update, `--report` will show it.

## Reviewing Notification Noise

Every hook invocation appends one line to a local event log — including the suppressed ones — so you can see where your notifications actually come from.
Clicks on notifications are recorded too (via the click callback), which tells you which notifications were worth acting on.

```bash
~/.claude/hooks/notify.sh --report      # summarize the last 7 days
~/.claude/hooks/notify.sh --report 2    # ...the last 2 days
```

The report shows delivered vs. suppressed counts, delivered notifications by type / project / session, the tab-less worker sessions that were skipped, click-through rate, and "bursts" — notifications landing within 60 seconds of the previous one, which is the pressure you feel when many parallel sessions ping at once.

The log is a plain TSV at `~/.local/state/claude-iterm-notify/events.tsv` with fields: timestamp, event, outcome, project, session, target, detail.
It is size-capped, with one `.old` generation kept (roughly weeks of data).
Permission/question message text is stored (truncated to 160 chars) in the detail column; set `NOTIFY_EVENT_LOG=0` to disable logging entirely, or point the variable at another path.
Uninstalling removes the log.

## Customizing

The hook script lives at `~/.claude/hooks/notify.sh`. Behavior is tunable via environment variables and a couple of in-script values:

| Variable | Default | Effect |
|----------|---------|--------|
| `NOTIFY_ALWAYS=1` | unset | Notify even for a session you're actively watching |
| `NOTIFY_DEBOUNCE_SECONDS` | `180` | Min seconds between "stop" notifications for the same session (loop dedup) |
| `NOTIFY_DEBOUNCE_DIR` | `/tmp/claude-iterm-notify-debounce` | Where per-session debounce stamps are kept |
| `NOTIFY_EVENT_LOG` | `~/.local/state/claude-iterm-notify/events.tsv` | Event-log path; `0` disables logging |
| `NOTIFY_HOLD_MAX_SECONDS` | `600` | Max seconds to hold a mid-work stop; `0` disables idle-gating |
| `NOTIFY_HOLD_POLL_SECONDS` | `10` | How often a held stop re-checks the tab title |
| `NOTIFY_AGENT_STOPS=1` | unset | Also notify when agent-team worker sessions stop |
| `NOTIFY_DEBUG=1` | unset | Write a decision trace to `/tmp/claude-iterm-notification-*.log` |

Other tweaks:
- **Disable "Ready for input"** — remove the `Stop` hook from `~/.claude/settings.json`.
- **Change the sound** — replace `-sound default` in the script (e.g. `-sound Ping`, `-sound Glass`; see `/System/Library/Sounds/`).
- **Debounce window** — `NOTIFY_DEBOUNCE_SECONDS` is read from the environment, or change the `180` default in the script. Permission/Question prompts are never debounced.

## Testing

A dependency-free test suite (pure bash, no `bats`) lives in `tests/`. It runs `notify.sh`/`install.sh`/`uninstall.sh` as subprocesses with mocked `tmux`, `osascript`, `terminal-notifier`, and `ps`, so it's safe to run anywhere (no real notifications, no config changes).

```bash
./tests/run.sh                 # run everything
./tests/run.sh test_notify.sh  # run one suite
```

(The harness sets `NOTIFY_TEST=1` so `notify.sh` skips its Homebrew PATH prepend and the mock tools on `PATH` take effect.)

Covers: tab resolution (direct tty / attached tmux / tab-less tmux → skip / no-tty fallback), `--focus` tab selection, session identification + subtitle, the watching-suppression and `NOTIFY_ALWAYS` override, durable-key debouncing, worker-session stop suppression, idle-gating (hold, supersede, cap, disable, late watching re-check), event logging (outcomes, clicks, rotation, disable, unwritable-path safety) and `--report`, and the install/uninstall settings.json merge & removal logic.

## Files

| File | Purpose |
|------|---------|
| `notify.sh` | The notification script (sending + click-to-focus) |
| `install.sh` / `uninstall.sh` | Set up / tear down the hook and settings entries |
| `tests/` | Test harness (`run.sh`, `lib.sh`, `test_*.sh`) |
| `~/.claude/hooks/notify.sh` | Installed copy of the script |
| `~/.claude/settings.json` | Claude Code settings (hook entries added by install) |

## Troubleshooting

Set `NOTIFY_DEBUG=1` (in the environment Claude Code runs in) to capture a trace at `/tmp/claude-iterm-notification-*.log` showing the detected tty, target, and decision.

| Problem | Fix |
|---------|-----|
| Too many notifications | Run `~/.claude/hooks/notify.sh --report` to see which sessions/types are noisy |
| No notifications | Run `which terminal-notifier`; ensure macOS notifications are allowed for terminal-notifier |
| No sound | System Settings > Notifications > terminal-notifier > enable Sounds |
| Click doesn't switch tab (tmux) | Ensure `tmux` is installed and the session still exists; check the debug log for the resolved client tty |
| No notification while in a loop | Expected — OMC loop "stop" events are debounced to once per `NOTIFY_DEBOUNCE_SECONDS`; Permission/Question always fire |
| No notification for the tab I'm on | Expected — suppressed while you're watching it; set `NOTIFY_ALWAYS=1` to override |
| "Ready for input" arrives ~10s after the summary | Expected — idle-gating polls the tab title every `NOTIFY_HOLD_POLL_SECONDS` |
| No stop notification from a fleet/worker tab | Expected — `--agent-id` sessions don't notify on stop; `NOTIFY_AGENT_STOPS=1` restores |

## License

MIT
