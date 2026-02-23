# Claude Code iTerm2 Notifications

Native macOS notifications when [Claude Code](https://docs.anthropic.com/en/docs/claude-code) needs your attention, with click-to-focus that takes you to the exact iTerm2 tab.

## What You Get

| Event | Notification |
|-------|-------------|
| Claude finishes responding | **ProjectName** — "Ready for input" |
| Claude needs tool permission | **ProjectName — Permission** — the permission message |
| Claude asks you a question | **ProjectName — Question** — the question text |

Each notification shows the **iTerm tab title** as a subtitle and clicking it switches to the correct iTerm2 tab — even across multiple windows.

## Requirements

- macOS
- [iTerm2](https://iterm2.com)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- [Homebrew](https://brew.sh) (for installing terminal-notifier)

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

Removes the hook script and hook entries from your settings. Optionally uninstalls terminal-notifier.

## How It Works

Claude Code's [hook system](https://docs.anthropic.com/en/docs/claude-code/hooks) triggers a shell script on specific events. The script:

1. Reads the hook's JSON payload from stdin (contains working directory, message, etc.)
2. Reads `ITERM_SESSION_ID` from the environment (iTerm2 sets this in every tab)
3. Queries the iTerm tab title via AppleScript
4. Fires `terminal-notifier` with a click callback
5. On click, an AppleScript finds the iTerm2 session by its unique ID and selects that tab

```
Claude Code hook fires
  → notify.sh reads JSON + ITERM_SESSION_ID
  → terminal-notifier shows macOS notification
  → user clicks notification
  → notify.sh --focus runs AppleScript
  → iTerm2 switches to the correct tab
```

## Hooks Configured

| Hook Event | Matcher | What fires it |
|-----------|---------|---------------|
| `Stop` | — | Claude finished responding |
| `Notification` | `permission_prompt` | Claude needs tool approval |
| `Notification` | `elicitation_dialog` | Claude is asking a question |

## Customizing

The hook script lives at `~/.claude/hooks/notify.sh`. Some things you might want to tweak:

- **Disable "Ready for input" notifications** — Remove the `Stop` hook from `~/.claude/settings.json` if they're too frequent. The permission and question notifications are usually the most useful.
- **Change the sound** — Replace `-sound default` in the script with any sound from `/System/Library/Sounds/` (e.g., `-sound Ping`, `-sound Glass`).
- **Adjust grouping** — Notifications are grouped by iTerm session ID, so a new notification replaces the previous one from the same session. Change the `-group` value to adjust this.

## Files

| File | Purpose |
|------|---------|
| `~/.claude/hooks/notify.sh` | The notification script (handles both sending and click-to-focus) |
| `~/.claude/settings.json` | Claude Code settings (hooks entries added by install) |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| No notifications | Run `which terminal-notifier` — needs to be in PATH |
| No sound | System Settings > Notifications > terminal-notifier > enable Sounds |
| Click doesn't switch tab | Run `echo $ITERM_SESSION_ID` — if empty, you're not in iTerm2 |
| Notifications are too noisy | Remove the `Stop` hook, keep only `Notification` hooks |

## License

MIT
