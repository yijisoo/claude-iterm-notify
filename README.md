# Claude Code iTerm2 Notifications

Native macOS notifications when [Claude Code](https://docs.anthropic.com/en/docs/claude-code) needs your attention, with click-to-focus that takes you to the exact iTerm2 tab — including sessions running inside **tmux** (e.g. [oh-my-claudecode](https://github.com/) orchestration).

## What You Get

| Event | Notification |
|-------|-------------|
| Claude finishes responding | **ProjectName** — "Ready for input" |
| Claude needs tool permission | **ProjectName — Permission** — the permission message |
| Claude asks you a question | **ProjectName — Question** — the question text |

- **Subtitle** shows what Claude was doing (the iTerm2 session name, or the tmux pane title for tmux sessions).
- **Click** switches to the correct iTerm2 tab — across multiple windows, and across tmux attach/detach.
- **No nagging**: notifications are suppressed for a session you're already looking at, and rapid "stop" events (OMC loop modes) are debounced.

## Requirements

- macOS
- [iTerm2](https://iterm2.com)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- [Homebrew](https://brew.sh) (for installing terminal-notifier)

> Optional: if you happen to run Claude inside **tmux** (e.g. via OMC), the script uses `tmux` to map the session back to its tab. It's not required for plain iTerm2 usage.

## Install

```bash
git clone https://github.com/stevemeisner/claude-iterm-notify.git
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

**When a notification fires:**
1. Read the hook's JSON payload from stdin (working directory → project name, message, etc.).
2. Walk up the process tree to find the controlling tty of the `claude` process.
3. Pick a durable handle:
   - tty is a **tmux pane** → use the **tmux session name** (survives detach/reattach); subtitle = pane title.
   - otherwise → use the **iTerm2 tty** directly; subtitle = iTerm2 session name.
4. If you're already watching that session (iTerm2 frontmost + that tab selected), **skip** the notification.
5. Otherwise fire `terminal-notifier` with a click callback carrying the handle.

**When you click:**
- `tty:<path>` → focus the iTerm2 tab with that tty.
- `tmux:<session>` attached → focus the iTerm2 tab currently showing it.
- `tmux:<session>` detached → open a new tab and `tmux attach` to it (great for OMC background agents).

```
Claude Code hook fires
  → notify.sh finds the session's tty (+ tmux session if any)
  → suppressed if you're already watching it
  → debounced if it pinged for this session recently
  → terminal-notifier shows the notification
  → you click
  → notify.sh --focus resolves the current tab and switches to it
```

## Hooks Configured

| Hook Event | Matcher | What fires it |
|-----------|---------|---------------|
| `Stop` | — | Claude finished responding |
| `Notification` | `permission_prompt` | Claude needs tool approval |
| `Notification` | `elicitation_dialog` | Claude is asking a question |

## tmux & OMC

If Claude runs inside a tmux session (as [oh-my-claudecode](https://github.com/) does — one tmux session per agent), the tab you see is just a *client* attached to that session. `notify.sh` maps `pane tty → tmux session → attached client tty → iTerm2 tab`, so click-to-focus lands on the right tab. If the session is **detached** when you click, it's re-attached in a new tab.

`tmux` is found even from terminal-notifier's minimal-PATH click callback (the script prepends Homebrew's bin).

## Customizing

The hook script lives at `~/.claude/hooks/notify.sh`. Behavior is tunable via environment variables and a couple of in-script values:

| Variable | Default | Effect |
|----------|---------|--------|
| `NOTIFY_ALWAYS=1` | unset | Notify even for a session you're actively watching |
| `NOTIFY_DEBOUNCE_SECONDS` | `180` | Min seconds between "stop" notifications for the same session (loop dedup) |
| `NOTIFY_DEBOUNCE_DIR` | `/tmp/claude-iterm-notify-debounce` | Where per-session debounce stamps are kept |
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

Covers: click-to-focus routing (direct tty / attached tmux / detached tmux / missing session), session identification + subtitle, the watching-suppression and `NOTIFY_ALWAYS` override, stop debouncing, and the install/uninstall settings.json merge & removal logic.

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
| No notifications | Run `which terminal-notifier`; ensure macOS notifications are allowed for terminal-notifier |
| No sound | System Settings > Notifications > terminal-notifier > enable Sounds |
| Click doesn't switch tab (tmux) | Ensure `tmux` is installed and the session still exists; check the debug log for the resolved client tty |
| No notification while in a loop | Expected — OMC loop "stop" events are debounced to once per `NOTIFY_DEBOUNCE_SECONDS`; Permission/Question always fire |
| No notification for the tab I'm on | Expected — suppressed while you're watching it; set `NOTIFY_ALWAYS=1` to override |

## License

MIT
